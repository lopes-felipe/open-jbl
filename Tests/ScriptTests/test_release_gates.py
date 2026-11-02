"""Release attestations cannot escape evidence directories or silently ungate."""
import copy
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class ReleaseGateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name) / "repo"
        for directory in ("scripts", "docs", "Tests/JBLKitTests/Fixtures/tourpro3"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "scripts/check-release-gates.py", self.root / "scripts")
        self.original = json.loads((ROOT / "docs/acceptance.json").read_text())
        self.report = copy.deepcopy(self.original)
        self.report.update(
            m1Outcome="A", m1EvidenceReport="docs/m1-evidence.md", inventoryFrozen=True,
            requiredActions=[{"hardwareVerified": True, "fixture": "tourpro3/proof.race.txt"}],
            checks={key: True for key in self.original["checks"]},
        )
        (self.root / "docs/m1-evidence.md").write_text("Synthetic test-only manual attestation.")
        (self.root / "Tests/JBLKitTests/Fixtures/tourpro3/proof.race.txt").write_text("Synthetic evidence.")

    def run_gate(self, report=None):
        (self.root / "docs/acceptance.json").write_text(json.dumps(self.report if report is None else report))
        return subprocess.run(
            ["python3", str(self.root / "scripts/check-release-gates.py")],
            capture_output=True, text=True, timeout=5,
        )

    def test_current_incomplete_attestations_stay_blocked(self):
        result = self.run_gate(self.original)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("M1 outcome A/B has not passed", result.stderr)
        self.assertIn("required-action inventory is empty", result.stderr)

    def test_complete_recorded_attestations_still_require_artifact_validation(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Notarization and artifact validation still required", result.stdout)

    def test_absolute_and_parent_traversal_fixture_paths_are_rejected(self):
        for path in ("../../../../docs/m1-evidence.md", str(self.root / "docs/m1-evidence.md")):
            with self.subTest(path=path):
                self.report["requiredActions"][0]["fixture"] = path
                result = self.run_gate()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("outside the fixture directory", result.stderr)

    def test_symlink_outside_fixture_directory_is_rejected(self):
        fixture = self.root / "Tests/JBLKitTests/Fixtures/tourpro3/link.txt"
        fixture.symlink_to(self.root / "docs/m1-evidence.md")
        self.report["requiredActions"][0]["fixture"] = "tourpro3/link.txt"
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside the fixture directory", result.stderr)

    def test_report_path_cannot_escape_docs(self):
        self.report["m1EvidenceReport"] = "docs/../Tests/JBLKitTests/Fixtures/tourpro3/proof.race.txt"
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside docs", result.stderr)

    def test_non_boolean_attestations_are_rejected(self):
        self.report["checks"]["noPairingOrPaging"] = "true"
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("noPairingOrPaging", result.stderr)

    def test_malformed_report_shape_fails_closed(self):
        self.assertNotEqual(self.run_gate([]).returncode, 0)
        self.report["checks"] = []
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checks must be an object", result.stderr)


if __name__ == "__main__":
    unittest.main()
