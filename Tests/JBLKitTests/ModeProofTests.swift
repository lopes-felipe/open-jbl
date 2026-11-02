import Foundation
import Testing
@testable import JBLKit

struct ResearchExchange: Sendable {
    let request: RaceFrame
    let replies: [RaceFrame]
}

/// Lock-confined value-only replay. It rejects an unexpected request sequence.
final class ResearchLink: Link, @unchecked Sendable {
    let generation: UInt64 = 1
    let events = OrderedMailbox(generation: 1)
    private let lock = NSLock()
    private let exchanges: [ResearchExchange]
    private let device: DeviceReference
    private let pauseAt: Int?
    let entered = PendingSlot<Void>()
    let resume = PendingSlot<Void>()
    private var opened = false
    private var openAttempts = 0
    private var closed = false
    private var sent: [RaceFrame] = []
    var boundDevice: DeviceReference? { lock.withLock { opened && !closed ? device : nil } }
    var writes: [RaceFrame] { lock.withLock { sent } }
    var isClosed: Bool { lock.withLock { closed } }
    var openCount: Int { lock.withLock { openAttempts } }
    init(_ exchanges: [ResearchExchange], pauseAt: Int? = nil) {
        self.exchanges = exchanges; self.pauseAt = pauseAt
        device = DeviceReference(address: "11-22-33-44-55-66", name: "JBL Tour Pro 3")
    }
    func maximumWriteLength(_ endpoint: LinkEndpoint) -> Int { 100 }
    func open() async throws { lock.withLock { opened = true; openAttempts += 1 }; events.enqueue(.opened) }
    func write(_ fragment: Data, to endpoint: LinkEndpoint) async throws {
        let frame = try RaceFrame.exact(fragment)
        let (number, replies) = try lock.withLock { () throws -> (Int, [RaceFrame]) in
            guard !closed, sent.count < exchanges.count,
                  exchanges[sent.count].request == frame else {
                throw LinkError.unavailable("Unexpected replay request")
            }
            let replies = exchanges[sent.count].replies
            sent.append(frame)
            return (sent.count, replies)
        }
        if number == pauseAt {
            entered.finish(.success(()))
            try await resume.wait()
        }
        events.enqueue(.writeCompleted(UInt64(number)))
        for reply in replies { events.enqueue(.data(.control, try reply.encoded())) }
    }
    func close() async {
        lock.withLock { closed = true }
        resume.finish(.failure(LinkError.disconnected))
        events.enqueue(.closed(nil))
    }
}

@Suite struct ModeProofTests {
    private func permit() -> AcquisitionPermit {
        AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
    }
    private func request(_ name: String) throws -> RaceFrame {
        try #require(OperationCatalog.production[name]).encode(.none)
    }
    private func firmware(_ version: String = "6.0.1") throws -> ResearchExchange {
        let text = Data(("v" + version).utf8)
        return ResearchExchange(request: try request("earbud-firmware"), replies: [
            RaceFrame(kind: .response, id: 0x1C07, payload: Data([0])),
            RaceFrame(kind: .notification, id: 0x1C07,
                      payload: Data([0, 0, UInt8(text.count)]) + text)
        ])
    }
    private func read(_ mode: TourPro3Sound.ListeningMode, fields: [UInt8]? = nil) throws -> ResearchExchange {
        ResearchExchange(request: try request("listening-mode"), replies: [
            RaceFrame(kind: .response, id: 0x0901,
                      payload: Data([5, 0, 0, mode.rawValue] + (fields ?? [7, 0, mode == .anc ? 5 : 6])))
        ])
    }
    private func write(_ mode: TourPro3Sound.ListeningMode, badStatus: Bool = false) throws -> ResearchExchange {
        let command = try request(mode == .anc ? "test-anc" : "test-ambient")
        // State-before-ACK is intentional. Both must be accepted, then read back.
        return ResearchExchange(request: command, replies: [
            RaceFrame(kind: .notification, id: 0x0901, payload: Data([5, 0, 0, mode.rawValue, 7, 0])),
            RaceFrame(kind: .response, id: 0x0E06,
                      payload: command.payload + Data([badStatus ? 1 : 0, 0]))
        ])
    }

    @Test func capturedModeRequestsAreByteExact() throws {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let text = try String(contentsOf: root.appendingPathComponent(
            "tourpro3/listening-mode-session-003.race.txt"), encoding: .utf8)
        let commands = try text.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("> ") }.map { try Data(hex: String($0.dropFirst(2))) }
        #expect(try request("test-ambient").encoded() == commands[0])
        #expect(try request("test-anc").encoded() == commands[1])
    }

    @Test func callerFlagsCannotSubstituteForTransportIdentity() async throws {
        let link = FakeLink()
        let session = GuardedSession(link: link, permit: permit(),
                                     context: PolicyContext(identityVerified: true, firmwareKnown: true))
        try await session.start()
        await #expect(throws: PolicyError.identityRequired) {
            try await session.perform(OperationRequest("test-ambient"))
        }
        #expect(link.writes.isEmpty)
        await session.stop()
    }

    @Test func callerFlagsCannotSubstituteForLiveFirmware() async throws {
        let link = ResearchLink([])
        let session = GuardedSession(link: link, permit: permit(),
                                     context: PolicyContext(identityVerified: true, firmwareKnown: true))
        try await session.start()
        await #expect(throws: PolicyError.unknownFirmware) {
            try await session.perform(OperationRequest("test-ambient"))
        }
        #expect(link.writes.isEmpty)
        await session.stop()
    }

    @Test(arguments: [TourPro3Sound.ListeningMode.ambient, .anc])
    func confirmedOnlyAfterStateAndFreshRead(mode: TourPro3Sound.ListeningMode) async throws {
        let original: TourPro3Sound.ListeningMode = mode == .anc ? .ambient : .anc
        let link = ResearchLink(try [firmware(), read(original), write(mode), read(mode)])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext())
        try await session.start()
        _ = try await session.perform(OperationRequest("earbud-firmware"))
        let result = try await session.perform(OperationRequest(mode == .anc ? "test-anc" : "test-ambient"))
        #expect(result == .confirmedMode(mode, changed: true))
        #expect(link.writes.count == 4)
        #expect(link.writes.filter { $0.id == 0x0E06 }.count == 1)
        await session.stop()
    }

    @Test func unknownFirmwareDoesNotEnableWrites() async throws {
        let link = ResearchLink(try [firmware("6.0.2")])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext())
        try await session.start()
        _ = try await session.perform(OperationRequest("earbud-firmware"))
        await #expect(throws: PolicyError.unknownFirmware) {
            try await session.perform(OperationRequest("test-ambient"))
        }
        #expect(link.writes.count == 1)
        await session.stop()
    }

    @Test func refusedFirmwareQueryCannotGrantWritePermission() async throws {
        let captured = try firmware()
        let refused = ResearchExchange(request: captured.request, replies: [
            RaceFrame(kind: .response, id: 0x1C07, payload: Data([1])),
            captured.replies[1]
        ])
        let link = ResearchLink([refused])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext())
        try await session.start()
        await #expect(throws: LinkError.unavailable("Unrecognized firmware reply")) {
            try await session.perform(OperationRequest("earbud-firmware"))
        }
        #expect(link.writes.count == 1)
        #expect(link.isClosed)
    }

    @Test func unsolicitedFirmwareAloneDoesNotGrantWritePermission() async throws {
        let version = try firmware().replies[1]
        let caseRead = ResearchExchange(request: try request("case-firmware"), replies: [
            version,
            RaceFrame(kind: .response, id: 0x000F, payload: Data([0])),
            RaceFrame(kind: .notification, id: 0x000F, payload: Data([0]) + Data("5.7.0".utf8))
        ])
        let link = ResearchLink([caseRead])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext())
        try await session.start()
        _ = try await session.perform(OperationRequest("case-firmware"))
        #expect(await session.observedFirmware().earbuds == "6.0.1")
        await #expect(throws: PolicyError.unknownFirmware) {
            try await session.perform(OperationRequest("test-ambient"))
        }
        #expect(link.writes.count == 1)
        await session.stop()
    }

    @Test func closedBindingRevokesWritePermission() async throws {
        let link = ResearchLink(try [firmware()])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext())
        try await session.start()
        _ = try await session.perform(OperationRequest("earbud-firmware"))
        await link.close()
        await #expect(throws: PolicyError.identityRequired) {
            try await session.perform(OperationRequest("test-ambient"))
        }
        #expect(link.writes.count == 1)
        await session.stop()
    }

    @Test func differentBaselinePreventsModeWrite() async throws {
        let link = ResearchLink(try [firmware(), read(.anc, fields: [6, 0, 5])])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext())
        try await session.start()
        _ = try await session.perform(OperationRequest("earbud-firmware"))
        await #expect(throws: ModeTestError.baselineMismatch) {
            try await session.perform(OperationRequest("test-ambient"))
        }
        #expect(link.writes.map(\.id) == [0x1C07, 0x0901])
        #expect(link.isClosed)
    }

    @Test(arguments: [TourPro3Sound.ListeningMode.anc, .ambient])
    func anotherModesOpaqueSuffixCannotPassBaseline(mode: TourPro3Sound.ListeningMode) async throws {
        let link = ResearchLink(try [firmware(), read(mode, fields: [7, 0, mode == .anc ? 6 : 5])])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext())
        try await session.start()
        _ = try await session.perform(OperationRequest("earbud-firmware"))
        await #expect(throws: ModeTestError.baselineMismatch) {
            try await session.perform(OperationRequest(mode == .anc ? "test-ambient" : "test-anc"))
        }
        #expect(link.writes.map(\.id) == [0x1C07, 0x0901])
        #expect(link.isClosed)
    }

    @Test(arguments: [[UInt8](arrayLiteral: 7, 0, 5), [7, 0, 7], [6, 0, 6], [7, 1, 6]])
    func unknownOrWrongModeReadbackNeverConfirms(fields: [UInt8]) async throws {
        let link = ResearchLink(try [firmware(), read(.anc), write(.ambient), read(.ambient, fields: fields)])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext())
        try await session.start()
        _ = try await session.perform(OperationRequest("earbud-firmware"))
        await #expect(throws: ModeTestError.unconfirmed) {
            try await session.perform(OperationRequest("test-ambient"))
        }
        #expect(link.writes.filter { $0.id == 0x0E06 }.count == 1)
        #expect(link.isClosed)
    }

    @Test func mismatchedReadbackIsUnconfirmedWithoutRetry() async throws {
        let link = ResearchLink(try [firmware(), read(.anc), write(.ambient), read(.anc)])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext())
        try await session.start()
        _ = try await session.perform(OperationRequest("earbud-firmware"))
        await #expect(throws: ModeTestError.unconfirmed) {
            try await session.perform(OperationRequest("test-ambient"))
        }
        #expect(link.writes.filter { $0.id == 0x0E06 }.count == 1)
        #expect(link.isClosed)
    }

    @Test func changedOpaqueReadbackIsNotConfirmedOrAutomaticallyRestored() async throws {
        // Synthetic field difference; no interpretation of the real hardware
        // mismatch is inferred from this test value.
        let link = ResearchLink(try [firmware(), read(.anc), write(.ambient),
                                     read(.ambient, fields: [7, 0, 4])])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext())
        try await session.start()
        _ = try await session.perform(OperationRequest("earbud-firmware"))
        await #expect(throws: ModeTestError.unconfirmed) {
            try await session.perform(OperationRequest("test-ambient"))
        }
        #expect(link.writes.filter { $0.id == 0x0E06 }.count == 1)
        #expect(link.isClosed)
    }

    @Test func nonzeroStatusIsNotSuccess() async throws {
        let link = ResearchLink(try [firmware(), read(.anc), write(.ambient, badStatus: true)])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext())
        try await session.start()
        _ = try await session.perform(OperationRequest("earbud-firmware"))
        await #expect(throws: ModeTestError.acknowledgementMismatch) {
            try await session.perform(OperationRequest("test-ambient"))
        }
        #expect(link.writes.count == 3)
        #expect(link.isClosed)
    }

    @Test func alreadySelectedModeDoesNotSendWrite() async throws {
        let link = ResearchLink(try [firmware(), read(.anc)])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext())
        try await session.start()
        _ = try await session.perform(OperationRequest("earbud-firmware"))
        #expect(try await session.perform(OperationRequest("test-anc")) == .confirmedMode(.anc, changed: false))
        #expect(link.writes.count == 2)
        await session.stop()
    }

    @Test func anotherOperationCannotInterleaveWithModeProof() async throws {
        let link = ResearchLink(try [firmware(), read(.anc), write(.ambient), read(.ambient)], pauseAt: 2)
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext())
        try await session.start()
        _ = try await session.perform(OperationRequest("earbud-firmware"))
        let changing = Task { try await session.perform(OperationRequest("test-ambient")) }
        try await link.entered.wait()
        await #expect(throws: PolicyError.busy) {
            try await session.perform(OperationRequest("case-firmware"))
        }
        link.resume.finish(.success(()))
        #expect(try await changing.value == .confirmedMode(.ambient, changed: true))
        #expect(link.writes.count == 4)
        await session.stop()
    }
}
