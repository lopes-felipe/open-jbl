import Foundation
import Testing
@testable import JBLKit

@Suite struct TourPro3TelemetryTests {
    private func capturedFrames() throws -> [RaceFrame] {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let fixture = root.appendingPathComponent("tourpro3/telemetry-session-004.race.txt")
        return try String(contentsOf: fixture, encoding: .utf8).split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("> ") || $0.hasPrefix("< ") }
            .map { try RaceFrame.exact(Data(hex: String($0.dropFirst(2)))) }
    }

    @Test func batteryReportsMatchUserReadingsWithoutAssumingSides() throws {
        let frames = try capturedFrames()
        #expect(frames.count == 11)
        let reports = frames.compactMap(TourPro3Telemetry.decodeBattery)
        #expect(reports.map(\.component) == [.agent, .chargingCase, .partner])
        #expect(reports.map(\.percent) == [45, 16, 49])
        let ack = try #require(frames.first { $0.kind == .response && $0.id == 0x000F })
        #expect(TourPro3Telemetry.decodeBattery(ack) == nil)
    }

    @Test func firmwareMatchesReportedVersionsAndAckIsNotState() throws {
        let frames = try capturedFrames()
        let versions = frames.compactMap(TourPro3Telemetry.decodeFirmware)
        #expect(versions.map(\.component) == [.earbuds, .chargingCase])
        #expect(versions.map(\.version) == ["6.0.1", "5.7.0"])
        let ack = try #require(frames.first { $0.kind == .response && $0.id == 0x000F })
        #expect(TourPro3Telemetry.decodeFirmware(ack) == nil)
        #expect(OperationCatalog.production["earbud-firmware"] != nil)
        #expect(Blocklists.race(0x1C07))
    }

    @Test func enabledReadsMatchExactCapturedRequests() throws {
        let frames = try capturedFrames()
        let requests = frames.filter { $0.kind == .command }
        let telemetryNames = ["battery-agent", "battery-partner", "case-firmware"]
        #expect(requests.count == telemetryNames.count)
        for name in telemetryNames {
            let (spec, bytes) = try SendPolicy.validate(OperationRequest(name), in: .production, context: PolicyContext())
            guard case .captured(let fixture, firmwareIndependent: true) = spec.evidence else {
                Issue.record("Bootstrap read lacks reviewed capture"); continue
            }
            #expect(fixture == "tourpro3/telemetry-session-004.race.txt")
            #expect(try requests.contains { try $0.encoded() == bytes })
            #expect(!Blocklists.race(try RaceFrame.exact(bytes).id))
        }
    }

    @Test func unsolicitedFirmwareIsObservedAndInvalidatedOnClose() async throws {
        let captured = try capturedFrames()
        let replies = captured.filter { $0.id == 0x1C07 || ($0.id == 0x000F && $0.kind != .command) }
        let link = FakeLink(replies: replies)
        let permit = AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
        let session = GuardedSession(link: link, permit: permit, context: PolicyContext())
        try await session.start()
        _ = try await session.perform(OperationRequest("case-firmware"))
        let observed = await session.observedFirmware()
        #expect(observed.earbuds == "6.0.1")
        #expect(observed.chargingCase == "5.7.0")
        #expect(link.writes.count == 1) // no blocked firmware query
        await session.stop()
        let closed = await session.observedFirmware()
        #expect(closed.earbuds == nil && closed.chargingCase == nil)
    }

    @Test func approvedFirmwareReadMatchesCaptureAndDecodesLiveReply() async throws {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let text = try String(contentsOf: root.appendingPathComponent(TourPro3Reads.firmwareFixture),
                              encoding: .utf8)
        let frames = try text.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("> ") || $0.hasPrefix("< ") }
            .map { try RaceFrame.exact(Data(hex: String($0.dropFirst(2)))) }
        #expect(frames.count == 3)
        let (_, bytes) = try SendPolicy.validate(OperationRequest("earbud-firmware"),
                                                in: .production, context: PolicyContext())
        #expect(bytes == (try frames[0].encoded()))
        let link = FakeLink(replies: Array(frames.dropFirst()))
        let permit = AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
        let session = GuardedSession(link: link, permit: permit, context: PolicyContext())
        try await session.start()
        let result = try await session.perform(OperationRequest("earbud-firmware"))
        #expect(result == .response(Array(frames.dropFirst())))
        #expect(link.writes == [bytes])
        #expect(await session.observedFirmware().earbuds == "6.0.1")
        await session.stop()
    }

    @Test(arguments: ["battery-agent", "battery-partner", "case-firmware"])
    func capturedReadCompletesThroughProductionGuard(name: String) async throws {
        let captured = try capturedFrames()
        let (_, bytes) = try SendPolicy.validate(OperationRequest(name), in: .production, context: PolicyContext())
        let request = try RaceFrame.exact(bytes)
        let replies = captured.filter { $0.kind != .command && $0.id == request.id }
        let link = FakeLink(replies: replies)
        let permit = AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
        let session = GuardedSession(link: link, permit: permit, context: PolicyContext())
        try await session.start()
        let reply = try await session.perform(OperationRequest(name))
        guard case .response(let frames) = reply else { Issue.record("Missing reply"); return }
        #expect(frames.count == 2)
        #expect(link.writes == [bytes])
        if name == "case-firmware" {
            #expect(frames.compactMap(TourPro3Telemetry.decodeFirmware).first?.version == "5.7.0")
        } else {
            #expect(frames.compactMap(TourPro3Telemetry.decodeBattery).first?.component ==
                    (name == "battery-agent" ? .agent : .partner))
        }
        await session.stop()
    }

    @Test func invalidBatteryReportsStayUnknown() {
        let frames = [
            RaceFrame(kind: .response, id: 0x0CD6, payload: Data([0])),
            RaceFrame(kind: .notification, id: 0x0CD6, payload: Data([1, 0, 45])),
            RaceFrame(kind: .notification, id: 0x0CD6, payload: Data([0, 2, 45])),
            RaceFrame(kind: .notification, id: 0x0CD6, payload: Data([0, 0, 101])),
            RaceFrame(kind: .notification, id: 0x000B, payload: Data([0, 255])),
            RaceFrame(kind: .notification, id: 0x000B, payload: Data([0, 16, 1]))
        ]
        for frame in frames { #expect(TourPro3Telemetry.decodeBattery(frame) == nil) }
    }

    @Test func malformedVersionsAreRejected() {
        let payloads: [Data] = [
            Data([0, 0, 5]) + Data("v6.0.1".utf8), // bad declared length
            Data([1, 0, 6]) + Data("v6.0.1".utf8), // nonzero status
            Data([0, 1, 6]) + Data("v6.0.1".utf8), // unverified prefix
            Data([0, 0, 6]) + Data("x6.0.1".utf8), // missing v marker
            Data([0, 0, 6]) + Data("v6.x.1".utf8)
        ]
        for payload in payloads {
            #expect(TourPro3Telemetry.decodeFirmware(
                RaceFrame(kind: .notification, id: 0x1C07, payload: payload)) == nil)
        }
        let casePayloads = ["5.7", "5..0", "256.7.0", "5.7.0\u{0}"]
        for value in casePayloads {
            #expect(TourPro3Telemetry.decodeFirmware(RaceFrame(
                kind: .notification, id: 0x000F, payload: Data([0]) + Data(value.utf8))) == nil)
        }
    }

    @Test func capturedTelemetryAtEverySplitAndRedaction() throws {
        let frames = try capturedFrames()
        for frame in frames {
            let bytes = try frame.encoded()
            for split in 0...bytes.count {
                var codec = RaceCodec()
                let a = try codec.ingest(Data(bytes.prefix(split)), at: .zero)
                let b = try codec.ingest(Data(bytes.dropFirst(split)), at: .milliseconds(1))
                #expect(a + b == [frame])
            }
            #expect(!Redactor().frame(frame).contains("6.0.1"))
            #expect(!Redactor().frame(frame).contains("5.7.0"))
        }
        var stream = Data()
        for frame in frames { stream.append(try frame.encoded()) }
        var codec = RaceCodec()
        #expect(try codec.ingest(stream, at: .zero) == frames)
    }
}
