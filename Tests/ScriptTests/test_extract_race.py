"""Exercise the capture extractor with synthetic HCI traffic, never device captures."""
import pathlib
import shutil
import struct
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
FIELDS = [
    "frame.time_relative", "hci_h4.direction", "btl2cap.cid", "btatt.opcode",
    "btatt.handle", "btatt.value", "btspp.data", "btl2cap.payload",
]


@unittest.skipUnless(shutil.which("tshark"), "Wireshark/tshark is required for capture-tool tests")
class ExtractRaceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.capture = self.root / "synthetic.pcap"
        self.output = self.root / "trace.tsv"
        # PCAP link type 201: Bluetooth HCI H4 with a direction pseudoheader.
        header = struct.pack("<IHHIIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 201)
        race = bytes.fromhex("05 5C 02 00 01 03")
        att = b"\x1b" + struct.pack("<H", 0x10) + race
        l2cap = struct.pack("<HH", len(att), 4) + att
        self.hci_acl = struct.pack("<HH", 0x2001, len(l2cap)) + l2cap
        hci = b"\x02" + self.hci_acl
        packet = struct.pack(">I", 1) + hci
        record = struct.pack("<IIII", 1, 0, len(packet), len(packet)) + packet
        self.capture.write_bytes(header + record)

    def extract(self, *options):
        return subprocess.run(
            ["bash", str(ROOT / "scripts/extract-race.sh"), *options, str(self.capture), str(self.output)],
            capture_output=True, text=True, timeout=15,
        )

    def test_fields_and_att_payload_from_real_tshark(self):
        result = self.extract()
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = self.output.read_text().splitlines()
        self.assertEqual(lines[0].split("\t"), FIELDS)
        cells = lines[1].split("\t")
        self.assertEqual(len(cells), 8)
        self.assertEqual(int(cells[1], 0), 1)
        self.assertEqual(int(cells[2], 0), 4)
        self.assertEqual(int(cells[3], 0), 0x1B)
        self.assertEqual(int(cells[4], 0), 0x10)
        self.assertEqual(bytes.fromhex(cells[5].replace(":", "")), bytes.fromhex("05 5C 02 00 01 03"))
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.root.glob("*.tmp.*")), [])

    def test_failed_extraction_leaves_no_output_and_can_retry(self):
        original = self.capture.read_bytes()
        self.capture.write_text("invalid capture")
        self.assertNotEqual(self.extract().returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.root.glob("*.tmp.*")), [])
        self.capture.write_bytes(original)
        self.assertEqual(self.extract().returncode, 0)

    def test_packetlogger_acl_directions_without_h4_pseudoheader(self):
        records = []
        for packet_type in (2, 3):
            # PKLG's length includes timestamp (8 bytes), type (1), and HCI data.
            records.append(struct.pack(">III", len(self.hci_acl) + 9, 1_700_000_000, packet_type * 1000)
                           + bytes([packet_type]) + self.hci_acl)
        self.capture.write_bytes(b"".join(records))
        result = self.extract()
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = self.output.read_text().splitlines()
        self.assertEqual(lines[0].split("\t"), FIELDS)
        rows = [line.split("\t") for line in lines[1:]]
        self.assertEqual(len(rows), 2)
        self.assertTrue(all(len(row) == 8 for row in rows))
        self.assertEqual([int(row[1], 0) for row in rows], [0, 1])
        self.assertTrue(all(int(row[4], 0) == 0x10 for row in rows))
        self.assertTrue(all(bytes.fromhex(row[5].replace(":", "")) == bytes.fromhex("05 5C 02 00 01 03")
                            for row in rows))

    def test_existing_output_is_preserved(self):
        self.output.write_text("keep this transcript")
        self.assertNotEqual(self.extract().returncode, 0)
        self.assertEqual(self.output.read_text(), "keep this transcript")
        self.assertEqual(list(self.root.glob("*.tmp.*")), [])

    def test_observed_dynamic_att_cid_can_be_decoded_without_discovery(self):
        acl = bytearray(self.hci_acl)
        acl[6:8] = struct.pack("<H", 0x0043)
        packet = struct.pack(">I", 1) + b"\x02" + acl
        header = self.capture.read_bytes()[:24]
        record = struct.pack("<IIII", 1, 0, len(packet), len(packet)) + packet
        self.capture.write_bytes(header + record)
        result = self.extract("--att-cid", "0x0043")
        self.assertEqual(result.returncode, 0, result.stderr)
        row = self.output.read_text().splitlines()[1].split("\t")
        self.assertEqual(len(row), 8)
        self.assertEqual(int(row[2], 0), 0x0043)
        self.assertEqual(int(row[3], 0), 0x1B)
        self.assertEqual(bytes.fromhex(row[5].replace(":", "")), bytes.fromhex("05 5C 02 00 01 03"))

    def test_att_cid_arguments_are_bounded_hex_values(self):
        for value in ("0x10000", "43", "0xGG", "0x43,other", "-d"):
            with self.subTest(value=value):
                result = self.extract("--att-cid", value)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.output.exists())
                self.assertEqual(list(self.root.glob("*.tmp.*")), [])

    def test_dangling_symlink_is_preserved(self):
        target = self.root / "absent"
        self.output.symlink_to(target)
        self.assertNotEqual(self.extract().returncode, 0)
        self.assertTrue(self.output.is_symlink())
        self.assertFalse(target.exists())
        self.assertEqual(list(self.root.glob("*.tmp.*")), [])


if __name__ == "__main__":
    unittest.main()
