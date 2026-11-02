import Foundation
import Testing
@testable import JBLKit

/// FakeLink copies values only. The lock serializes callbacks and write accounting.
final class FakeLink: Link, @unchecked Sendable {
    let generation: UInt64 = 1
    let events: OrderedMailbox
    let mtu: Int
    let failAt: Int?
    let replies: [RaceFrame]
    private let lock = NSLock()
    private var fragments: [Data] = []
    private var opens = 0
    private var closes = 0
    private var cancelled = false
    let closedSlot = PendingSlot<Void>()
    init(mtu: Int = 100, failAt: Int? = nil, replies: [RaceFrame] = [], eventGeneration: UInt64 = 1) {
        self.mtu = mtu; self.failAt = failAt; self.replies = replies
        events = OrderedMailbox(generation: eventGeneration)
    }
    var writes: [Data] { lock.withLock { fragments } }
    var openCount: Int { lock.withLock { opens } }
    var closeCount: Int { lock.withLock { closes } }
    func maximumWriteLength(_ endpoint: LinkEndpoint) -> Int { mtu }
    func open() async throws { lock.withLock { opens += 1 }; events.enqueue(.opened) }
    func write(_ fragment: Data, to endpoint: LinkEndpoint) async throws {
        let number = lock.withLock { () -> Int in fragments.append(fragment); return fragments.count }
        if number == failAt { throw LinkError.io(-1) }
        try Task.checkCancellation()
        events.enqueue(.writeCompleted(UInt64(number)))
        for frame in replies { events.enqueue(.data(.control, try frame.encoded())) }
    }
    func close() async {
        lock.withLock { closes += 1; cancelled = true }
        events.enqueue(.closed(nil))
        closedSlot.finish(.success(()))
    }
}

actor PausedLink: Link {
    nonisolated let generation: UInt64 = 1
    nonisolated let events = OrderedMailbox(generation: 1)
    let entered = PendingSlot<Void>()
    let resume = PendingSlot<Void>()
    var writes = 0
    var closed = false
    nonisolated func maximumWriteLength(_ endpoint: LinkEndpoint) -> Int { 3 }
    func open() async throws { events.enqueue(.opened) }
    func write(_ fragment: Data, to endpoint: LinkEndpoint) async throws {
        writes += 1
        entered.finish(.success(()))
        try await resume.wait()
    }
    func close() async {
        closed = true
        resume.finish(.failure(LinkError.disconnected))
        events.enqueue(.closed(nil))
    }
}

@Suite struct ConcurrencyTests {
    @Test func mailboxOrderAndTerminalSlot() async throws {
        let mailbox = OrderedMailbox(generation: 7, maxBytes: 4, maxEvents: 3)
        #expect(mailbox.enqueue(.data(.control, Data([1]))))
        #expect(mailbox.enqueue(.writeCompleted(1)))
        #expect(mailbox.enqueue(.data(.control, Data([2]))))
        #expect(!mailbox.enqueue(.data(.control, Data([3]))))
        #expect(!mailbox.enqueue(.opened))
        var result: [SequencedEvent] = []
        while let item = try await mailbox.next() { result.append(item) }
        #expect(result.map(\.sequence) == [1, 2, 3, 4])
        #expect(result.allSatisfy { $0.generation == 7 })
        #expect(result.last?.event == .closed(.overflow))
    }

    @Test func mailboxByteLimit() async throws {
        let mailbox = OrderedMailbox(generation: 1, maxBytes: 2)
        #expect(!mailbox.enqueue(.data(.control, Data([1, 2, 3]))))
        #expect(try await mailbox.next()?.event == .closed(.overflow))
        #expect(try await mailbox.next() == nil)
    }

    @Test func pendingSlotExactlyOnceAndCancellationBeforeInstall() async throws {
        let slot = PendingSlot<Int>()
        #expect(slot.finish(.success(42)))
        #expect(!slot.finish(.success(99)))
        #expect(try await slot.wait() == 42)
        let cancelled = PendingSlot<Int>()
        let task = Task { () throws -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cancelled.wait()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!cancelled.finish(.success(1)))
    }

    @Test func mailboxCancellationDoesNotTrapNextConsumer() async throws {
        let mailbox = OrderedMailbox(generation: 1)
        let task = Task { try await mailbox.next() }
        task.cancel()
        _ = try? await task.value
        mailbox.enqueue(.opened)
        #expect(try await mailbox.next()?.event == .opened)
    }

    @Test func fragmentAtMTU() async throws {
        let link = FakeLink(mtu: 3)
        let channel = FrameChannel(link: link)
        let bytes = Data(0..<20)
        try await channel.send(bytes)
        #expect(link.writes.count == 7)
        #expect(link.writes.allSatisfy { $0.count <= 3 })
        #expect(link.writes.reduce(Data(), +) == bytes)
    }

    @Test func partialFailurePoisonsAndPreventsNextFrame() async throws {
        let link = FakeLink(mtu: 3, failAt: 2)
        let channel = FrameChannel(link: link)
        await #expect(throws: LinkError.poisoned) { try await channel.send(Data(0..<20)) }
        #expect(link.writes.count == 2)
        #expect(link.closeCount == 1)
        await #expect(throws: LinkError.poisoned) { try await channel.send(Data([1])) }
        #expect(link.writes.count == 2)
    }

    @Test func emptyCatalogAndACLDownOpenNothing() async throws {
        let link = FakeLink()
        let permit = AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
        let session = GuardedSession(link: link, permit: permit, context: testContext([]), catalog: OperationCatalog([]))
        await #expect(throws: PolicyError.missingCapture) { try await session.start() }
        #expect(link.openCount == 0)
        permit.update(AcquisitionContext(selectedAndPaired: true, classicConnected: false, controlNeeded: true))
        await #expect(throws: PolicyError.connectionGuard) { try await session.start() }
        #expect(link.openCount == 0)
        #expect(link.writes.isEmpty)
    }

    @Test(arguments: [true, false])
    func batteryCompletionAcceptsEitherOrder(indicationFirst: Bool) async throws {
        let spec = testSpec(0x0CD6, completion: .responseThenIndication(
            response: 0x0CD6, indication: 0x0CD6, kind: .notification, role: 1, roleOffset: 1))
        let ack = RaceFrame(kind: .response, id: 0x0CD6, payload: Data([0]))
        let indication = RaceFrame(kind: .notification, id: 0x0CD6, payload: Data([0, 1, 49]))
        let wrongRole = RaceFrame(kind: .notification, id: 0x0CD6, payload: Data([0, 0, 45]))
        let wrongKind = RaceFrame(kind: .indication, id: 0x0CD6, payload: indication.payload)
        let link = FakeLink(replies: [wrongRole, wrongKind] + (indicationFirst ? [indication, ack] : [ack, indication]))
        let permit = AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
        let session = GuardedSession(link: link, permit: permit, context: testContext([spec]), catalog: OperationCatalog([spec]))
        try await session.start()
        let reply = try await session.perform(OperationRequest(spec.name))
        if case .response(let frames) = reply {
            #expect(frames.count == 2)
            #expect(frames.contains(indication))
            #expect(!frames.contains(wrongRole))
            #expect(!frames.contains(wrongKind))
        }
        await session.stop()
    }

    @Test(arguments: [true, false])
    func duplicateCompletionFramesAreBounded(indicationFirst: Bool) async throws {
        let spec = testSpec(0x0CD6, completion: .responseThenIndication(
            response: 0x0CD6, indication: 0x0CD6, kind: .notification, role: 1, roleOffset: 1))
        let ack = RaceFrame(kind: .response, id: 0x0CD6, payload: Data([0]))
        let indication = RaceFrame(kind: .notification, id: 0x0CD6, payload: Data([0, 1, 49]))
        let repeated = indicationFirst ? indication : ack
        let final = indicationFirst ? ack : indication
        let link = FakeLink(replies: Array(repeating: repeated, count: 100) + [final])
        let permit = AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
        let session = GuardedSession(link: link, permit: permit, context: testContext([spec]), catalog: OperationCatalog([spec]))
        try await session.start()
        let reply = try await session.perform(OperationRequest(spec.name))
        #expect(reply == .response(indicationFirst ? [indication, ack] : [ack, indication]))
        await session.stop()
    }

    @Test func notificationOnlyCompletionUsesDeclaredRoleField() async throws {
        let spec = testSpec(0x0CD6, completion: .indication(
            0x0CD6, kind: .notification, role: 1, roleOffset: 1))
        let expected = RaceFrame(kind: .notification, id: 0x0CD6, payload: Data([0, 1, 49]))
        let link = FakeLink(replies: [
            RaceFrame(kind: .notification, id: 0x0CD6, payload: Data([0, 0, 45])), expected
        ])
        let permit = AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
        let session = GuardedSession(link: link, permit: permit, context: testContext([spec]), catalog: OperationCatalog([spec]))
        try await session.start()
        #expect(try await session.perform(OperationRequest(spec.name)) == .response([expected]))
        await session.stop()
    }

    @Test(arguments: [-1, 3])
    func invalidRoleOffsetsCannotCompleteOrTrap(offset: Int) async throws {
        let spec = testSpec(0x0CD6, completion: .indication(
            0x0CD6, kind: .notification, role: 1, roleOffset: offset), deadline: .milliseconds(10))
        let link = FakeLink(replies: [
            RaceFrame(kind: .notification, id: 0x0CD6, payload: Data([0, 1, 49]))
        ])
        let permit = AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
        let session = GuardedSession(link: link, permit: permit, context: testContext([spec]), catalog: OperationCatalog([spec]))
        try await session.start()
        if offset < 0 {
            await #expect(throws: PolicyError.invalidMetadata) { try await session.perform(OperationRequest(spec.name)) }
            #expect(link.writes.isEmpty)
            await session.stop()
        } else {
            await #expect(throws: LinkError.timedOut) { try await session.perform(OperationRequest(spec.name)) }
        }
        #expect(link.closeCount >= 1)
    }

    @Test func timeoutClosesBeforeMatcherReuse() async throws {
        let spec = testSpec(deadline: .milliseconds(10))
        let link = FakeLink()
        let permit = AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
        let session = GuardedSession(link: link, permit: permit, context: testContext([spec]), catalog: OperationCatalog([spec]))
        try await session.start()
        await #expect(throws: LinkError.timedOut) { try await session.perform(OperationRequest(spec.name)) }
        #expect(link.closeCount >= 1)
        await #expect(throws: LinkError.disconnected) { try await session.perform(OperationRequest(spec.name)) }
        #expect(link.writes.count == 1)
    }

    @Test func rejectedSpecEmitsNoBytes() async throws {
        let spec = testSpec(evidence: .documented(source: "not a capture"))
        let link = FakeLink()
        let permit = AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
        let session = GuardedSession(link: link, permit: permit, context: testContext([spec]), catalog: OperationCatalog([spec]))
        try await session.start()
        await #expect(throws: PolicyError.missingCapture) { try await session.perform(OperationRequest(spec.name)) }
        #expect(link.writes.isEmpty)
        await session.stop()
    }

    @Test func frameLeaseReservedBeforeSuspension() async throws {
        let link = PausedLink()
        let channel = FrameChannel(link: link)
        let first = Task { try await channel.send(Data([1, 2, 3])) }
        try await link.entered.wait()
        await #expect(throws: PolicyError.busy) { try await channel.send(Data([4])) }
        #expect(await link.writes == 1)
        link.resume.finish(.success(()))
        try await first.value
    }

    @Test func cancellationDuringFragmentPoisons() async throws {
        let link = PausedLink()
        let channel = FrameChannel(link: link)
        let task = Task { try await channel.send(Data(0..<20)) }
        try await link.entered.wait()
        task.cancel()
        await #expect(throws: LinkError.poisoned) { try await task.value }
        #expect(await link.closed)
        #expect(await link.writes == 1)
        await #expect(throws: LinkError.poisoned) { try await channel.send(Data([4])) }
    }

    @Test func oldGenerationCannotCompleteTransaction() async throws {
        let spec = testSpec(deadline: .milliseconds(30))
        let link = FakeLink(replies: [RaceFrame(kind: .response, id: 0x0301)], eventGeneration: 0)
        let permit = AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
        let session = GuardedSession(link: link, permit: permit, context: testContext([spec]), catalog: OperationCatalog([spec]))
        try await session.start()
        // A valid reply from the old generation must not satisfy the new matcher.
        await #expect(throws: LinkError.timedOut) { try await session.perform(OperationRequest(spec.name)) }
        #expect(link.writes.count == 1)
    }

    @Test func sessionLeaseAndCloseCompletePendingCaller() async throws {
        let spec = testSpec()
        let link = PausedLink()
        let permit = AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
        let session = GuardedSession(link: link, permit: permit, context: testContext([spec]), catalog: OperationCatalog([spec]))
        try await session.start()
        let first = Task { try await session.perform(OperationRequest(spec.name)) }
        try await link.entered.wait()
        await #expect(throws: PolicyError.busy) { try await session.perform(OperationRequest(spec.name)) }
        await session.stop()
        await #expect(throws: (any Error).self) { try await first.value }
        #expect(await link.closed)
        #expect(await link.writes == 1)
    }

    @Test func abandonedSessionReleasesLink() async throws {
        let spec = testSpec()
        let link = FakeLink()
        let permit = AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
        var session: GuardedSession? = GuardedSession(link: link, permit: permit,
            context: testContext([spec]), catalog: OperationCatalog([spec]))
        try await session?.start()
        session = nil
        try await withDeadline(.seconds(1)) { try await link.closedSlot.wait() }
        #expect(link.closeCount >= 1)
    }
}
