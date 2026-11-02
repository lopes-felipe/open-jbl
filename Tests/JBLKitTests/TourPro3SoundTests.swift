import Foundation
import Testing
@testable import JBLKit

@Suite struct TourPro3SoundTests {
    private func capturedFrames() throws -> [RaceFrame] {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let fixture = root.appendingPathComponent("tourpro3/listening-mode-session-003.race.txt")
        return try String(contentsOf: fixture, encoding: .utf8).split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("> ") || $0.hasPrefix("< ") }
            .map { try RaceFrame.exact(Data(hex: String($0.dropFirst(2)))) }
    }

    @Test func capturedReportsMatchAudibleSequence() throws {
        let frames = try capturedFrames()
        #expect(frames.count == 6)
        let reports = frames.compactMap(TourPro3Sound.decodeListeningReport)
        #expect(reports.map(\.mode) == [.ambient, .anc])
        #expect(reports.map(\.opaqueFields) == [Data([7, 0]), Data([7, 0])])
        // A transport reply is not a listening-mode state report.
        #expect(TourPro3Sound.decodeListeningReport(frames[1]) == nil)
        #expect(TourPro3Sound.decodeListeningReport(frames[4]) == nil)
        #expect(OperationCatalog.production["set-listening-mode"] == nil)
    }

    @Test func capturedReadbackHasDistinctLayoutAndExactRequest() async throws {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let text = try String(contentsOf: root.appendingPathComponent(
            "tourpro3/listening-read-session-004.race.txt"), encoding: .utf8)
        let frames = try text.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("> ") || $0.hasPrefix("< ") }
            .map { try RaceFrame.exact(Data(hex: String($0.dropFirst(2)))) }
        #expect(frames.count == 2)
        let report = try #require(TourPro3Sound.decodeListeningReadback(frames[1]))
        #expect(report.mode == .anc)
        #expect(report.opaqueFields == Data([7, 0, 5]))
        #expect(TourPro3Sound.decodeListeningReport(frames[1]) == nil)
        #expect(TourPro3Sound.decodeListeningReadback(frames[0]) == nil)
        let (_, bytes) = try SendPolicy.validate(OperationRequest("listening-mode"),
                                                in: .production, context: PolicyContext())
        #expect(bytes == (try frames[0].encoded()))
        let link = FakeLink(replies: [frames[1]])
        let permit = AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
        let session = GuardedSession(link: link, permit: permit, context: PolicyContext())
        try await session.start()
        #expect(try await session.perform(OperationRequest("listening-mode")) == .response([frames[1]]))
        #expect(link.writes == [bytes])
        await session.stop()
    }

    @Test func malformedReadbacksDoNotBecomeState() {
        for frame in [
            RaceFrame(kind: .notification, id: 0x0901, payload: Data([5, 0, 0, 1, 7, 0, 5])),
            RaceFrame(kind: .response, id: 0x0900, payload: Data([5, 0, 0, 1, 7, 0, 5])),
            RaceFrame(kind: .response, id: 0x0901, payload: Data([5, 0, 0, 1, 7, 0])),
            RaceFrame(kind: .response, id: 0x0901, payload: Data([5, 0, 0, 4, 7, 0, 5])),
            RaceFrame(kind: .response, id: 0x0901, payload: Data([5, 1, 0, 1, 7, 0, 5]))
        ] { #expect(TourPro3Sound.decodeListeningReadback(frame) == nil) }
    }

    @Test func capturedModeProfilesKeepTheirDistinctOpaqueSuffixes() throws {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let text = try String(contentsOf: root.appendingPathComponent(
            "tourpro3/listening-profiles-session-005.race.txt"), encoding: .utf8)
        let frames = try text.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("> ") || $0.hasPrefix("< ") }
            .map { try RaceFrame.exact(Data(hex: String($0.dropFirst(2)))) }
        let reports = frames.compactMap(TourPro3Sound.decodeListeningReadback)
        #expect(reports.map(\.mode) == [.ambient, .anc])
        #expect(reports.map(\.opaqueFields) == [Data([7, 0, 6]), Data([7, 0, 5])])
        #expect(reports.allSatisfy(TourPro3ModeTests.matchesCapturedProfile))
        #expect(TourPro3ModeTests.successfulReply(frames[3], mode: .anc))
        // Exercise the new captured replies at every transport split.
        for frame in frames {
            let bytes = try frame.encoded()
            for split in 0...bytes.count {
                var codec = RaceCodec()
                let first = try codec.ingest(Data(bytes.prefix(split)), at: .zero)
                let last = try codec.ingest(Data(bytes.dropFirst(split)), at: .milliseconds(1))
                #expect(first + last == [frame])
            }
        }
    }

    @Test func capturedFramesAtEverySplit() throws {
        for frame in try capturedFrames() {
            let bytes = try frame.encoded()
            for split in 0...bytes.count {
                var codec = RaceCodec()
                let a = try codec.ingest(Data(bytes.prefix(split)), at: .zero)
                let b = try codec.ingest(Data(bytes.dropFirst(split)), at: .milliseconds(1))
                #expect(a + b == [frame])
            }
        }
    }

    @Test func unverifiedLayoutsAndModesAreNotDecoded() {
        let invalid: [RaceFrame] = [
            RaceFrame(kind: .response, id: 0x0901, payload: Data([5, 0, 0, 1, 7, 0])),
            RaceFrame(kind: .indication, id: 0x0901, payload: Data([5, 0, 0, 1, 7, 0])),
            RaceFrame(kind: .notification, id: 0x0900, payload: Data([5, 0, 0, 1, 7, 0])),
            RaceFrame(kind: .notification, id: 0x0901, payload: Data([5, 0, 0, 5, 7, 0])),
            RaceFrame(kind: .notification, id: 0x0901, payload: Data([6, 0, 0, 1, 7, 0])),
            RaceFrame(kind: .notification, id: 0x0901, payload: Data([5, 0, 0, 1, 7]))
        ]
        for frame in invalid {
            #expect(TourPro3Sound.decodeListeningReport(frame) == nil)
        }
    }
}
