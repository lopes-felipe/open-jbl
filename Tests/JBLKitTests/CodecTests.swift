import Foundation
import Testing
@testable import JBLKit

@Suite struct CodecTests {
    @Test func roundTripAndEverySplit() throws {
        let frames = [
            RaceFrame(kind: .command, id: 0x0301),
            RaceFrame(kind: .response, id: 0x0092, payload: Data([0, 5, 0x5A, 2, 0, 5, 0])),
            RaceFrame(kind: .indication, id: 0x0CD6, payload: Data([1, 89, 0]))
        ]
        for frame in frames {
            let encoded = try frame.encoded()
            #expect(try RaceFrame.exact(encoded) == frame)
            for split in 0...encoded.count {
                var codec = RaceCodec()
                let a = try codec.ingest(Data(encoded.prefix(split)), at: .zero)
                let b = try codec.ingest(Data(encoded.dropFirst(split)), at: .milliseconds(1))
                #expect(a + b == [frame])
                #expect(codec.bufferedByteCount == 0)
            }
        }
    }

    @Test func concatenationGarbageAndInvalidTypes() throws {
        let a = RaceFrame(kind: .response, id: 0x0301)
        let b = RaceFrame(kind: .indication, id: 0x0CD6, payload: Data([5, 5, 5]))
        let data = try Data([0, 0xFF, 5, 0x99, 5, 0x5A, 0, 0]) + a.encoded() + b.encoded()
        var codec = RaceCodec()
        #expect(try codec.ingest(data, at: .zero) == [a, b])
    }

    @Test func exactRejectsTrailingAndMultipleFrames() throws {
        let bytes = try RaceFrame(kind: .command, id: 0x0301).encoded()
        #expect(throws: RaceError.malformed) { try RaceFrame.exact(bytes + Data([0])) }
        #expect(throws: RaceError.malformed) { try RaceFrame.exact(bytes + bytes) }
        #expect(throws: RaceError.malformed) { try RaceFrame.exact(Data([5, 0x5A, 1, 0, 0])) }
        #expect(throws: ByteError.tooLarge) {
            try RaceFrame(kind: .command, id: 1, payload: Data(repeating: 0, count: 65_534)).encoded()
        }
    }

    @Test func expiryAndBoundedBuffer() throws {
        var codec = RaceCodec()
        #expect(try codec.ingest(Data([5, 0x5A, 10, 0]), at: .zero).isEmpty)
        try codec.expire(at: .seconds(4))
        #expect(throws: RaceError.partialExpired) { try codec.expire(at: .seconds(5)) }
        #expect(codec.bufferedByteCount == 0)
        #expect(throws: RaceError.overflow) {
            try codec.ingest(Data(repeating: 1, count: RaceCodec.maximumFrameLength * 2 + 1), at: .seconds(6))
        }
        #expect(codec.bufferedByteCount == 0)
    }

    @Test func randomizedInputIsBounded() throws {
        var seed: UInt64 = 42
        var codec = RaceCodec()
        for i in 0..<10_000 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let byte = UInt8(truncatingIfNeeded: seed >> 32)
            do { _ = try codec.ingest(Data([byte]), at: .milliseconds(i)) }
            catch { #expect(error is RaceError) }
            #expect(codec.bufferedByteCount <= RaceCodec.maximumFrameLength * 2)
        }
    }

    @Test func maximumLegalFrame() throws {
        let frame = RaceFrame(kind: .response, id: 1, payload: Data(repeating: 5, count: 65_533))
        var codec = RaceCodec()
        #expect(try codec.ingest(frame.encoded(), at: .zero) == [frame])
    }

    @Test func hexAndCRC() throws {
        #expect(try Data(hex: "05:5a-02 00\n01 03").hex == "05 5A 02 00 01 03")
        #expect(throws: ByteError.invalidHex) { try Data(hex: "050") }
        #expect(throws: ByteError.invalidHex) { try Data(hex: "zz") }
        #expect(CRC16.modbusZero("123456789".utf8) == 0xBB3D)
        #expect(CRC16.host(String(repeating: "x", count: 51)) == CRC16.host(String(repeating: "x", count: 50)))
        #expect(CRC16.host(String(repeating: "é", count: 30)) == CRC16.modbusZero(String(repeating: "é", count: 30).utf8.prefix(50)))
    }

    @Test func decoderKeepsStreamsSeparateAndRedacts() throws {
        let tsv = """
        frame.time_relative\thci_h4.direction\tbtl2cap.cid\tbtatt.opcode\tbtatt.handle\tbtatt.value\tbtspp.data\tbtl2cap.payload
        0.001\t0\t1\t\t\t\t05:5a:03\t
        0.002\t1\t1\t\t\t\t05:5b:02:00:01:03\t
        0.003\t0\t1\t\t\t\t00:01:03:ff\t
        0.004\t1\t2\t0x1b\t0x10\t05:5c:02:00:02:03\t\t05:5c:02:00:02:03
        """
        let records = try CaptureDecoder.decode(tsv)
        #expect(records.count == 3)
        #expect(records.map(\.frame.id) == [0x0301, 0x0301, 0x0302])
        #expect(records[1].frame.payload == Data([0xFF]))
        #expect(!Redactor().frame(records[1].frame).contains("FF"))
        #expect(throws: CaptureError.invalidTSV) { try CaptureDecoder.decode("not a TSV") }
    }

    @Test func decoderRecognizesWholeATTEnvelopesWithoutDiscovery() throws {
        let command = RaceFrame(kind: .command, id: 0x0E06, payload: Data([0, 10, 5, 0]))
        let update = RaceFrame(kind: .notification, id: 0x0901, payload: Data(repeating: 0, count: 6))
        let tsv = try [
            captureRow(Data([0x52, 0x53, 0]) + command.encoded(), direction: "0x00", cid: "0x0043"),
            captureRow(Data([0x1B, 0x55, 0]) + update.encoded(), direction: "0x01", cid: "0x050a")
        ].joined(separator: "\n")
        let records = try CaptureDecoder.decode(tsv)
        #expect(records.map(\.source) == ["ATT-candidate:0x0053", "ATT-candidate:0x0055"])
        #expect(records.map(\.direction) == ["0x00", "0x01"])
        #expect(records.map(\.frame) == [command, update])
        #expect(!Redactor().frame(command).contains(command.payload.hex))
    }

    @Test func attCandidateRequiresAnExactEnvelope() throws {
        let frame = try RaceFrame(kind: .command, id: 0x0301).encoded()
        let envelope = Data([0x52, 1, 0]) + frame
        let invalid: [Data] = [
            envelope + Data([0]), // trailing byte
            envelope + frame, // two frames
            Data([0x52, 0, 0]) + frame, // invalid attribute handle
            Data([0x12, 1, 0]) + frame, // unsupported ATT opcode
            Data([0, 0x52, 1, 0]) + frame, // embedded envelope
            Data([0x1B, 1, 0]) + Data(frame.dropLast()) // incomplete frame
        ]
        for value in invalid {
            let records = try CaptureDecoder.decode(captureRow(value))
            #expect(!records.contains { $0.source.hasPrefix("ATT-candidate:") })
        }
    }

    @Test func dissectedATTAndSPPTakePrecedenceOverCandidate() throws {
        let a = try RaceFrame(kind: .command, id: 0x0301).encoded()
        let b = try RaceFrame(kind: .response, id: 0x0092).encoded()
        let raw = (Data([0x52, 1, 0]) + b).hex
        let att = "0.001\t0\t1\t0x52\t0x0020\t\(a.hex)\t\t\(raw)"
        let spp = "0.001\t0\t1\t\t\t\t\(a.hex)\t\(raw)"
        #expect(try CaptureDecoder.decode(att).map(\.source) == ["ATT:0x0020"])
        #expect(try CaptureDecoder.decode(spp).map(\.source) == ["SPP"])
    }

    private func captureRow(_ raw: Data, direction: String = "0", cid: String = "1") -> String {
        "0.001\t\(direction)\t\(cid)\t\t\t\t\t\(raw.hex)"
    }
}
