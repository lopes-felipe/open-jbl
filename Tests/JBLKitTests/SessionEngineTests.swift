import Foundation
import Testing
@testable import JBLKit

/// Test-only owned values are lock confined; callbacks never retain Apple objects.
private final class TestSessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Duration = .zero
    private var sleepers: [(Duration, PendingSlot<Void>)] = []
    var clock: SessionClock {
        SessionClock(now: { self.lock.withLock { self.time } },
                     date: { Date(timeIntervalSince1970: 1_000) },
                     sleep: { duration in
            if duration <= .zero { return }
            let slot = PendingSlot<Void>()
            self.lock.withLock { self.sleepers.append((self.time + duration, slot)) }
            try await slot.wait()
        })
    }
    var sleeperCount: Int { lock.withLock { sleepers.count } }
    func hasSleeper(within duration: Duration) -> Bool {
        lock.withLock { sleepers.contains { $0.0 <= time + duration } }
    }
    func advance(_ duration: Duration) {
        let ready = lock.withLock {
            time += duration
            let ready = sleepers.filter { $0.0 <= time }
            sleepers.removeAll { $0.0 <= time }
            return ready
        }
        ready.forEach { $0.1.finish(.success(())) }
    }
}

private actor ReplaySessionConnection: SessionConnection {
    nonisolated let generation: UInt64 = 1
    private(set) var isActive = false
    private(set) var names: [String] = []
    private(set) var stops = 0
    var mode: TourPro3Sound.ListeningMode = .anc
    var failMode = false
    var failedReads: Set<String> = []
    var writeGate: PendingSlot<Void>?
    var readGate: PendingSlot<Void>?
    private let mailbox: OrderedMailbox?
    init(events: Bool = false) { mailbox = events ? OrderedMailbox(generation: 1) : nil }
    func start() { isActive = true }
    func stop() { isActive = false; stops += 1; mailbox?.enqueue(.closed(nil)) }
    func stateEvents() -> OrderedMailbox? { mailbox }
    func setWriteGate(_ gate: PendingSlot<Void>?) { writeGate = gate }
    func setReadGate(_ gate: PendingSlot<Void>?) { readGate = gate }
    func setFailMode(_ value: Bool) { failMode = value }
    func failReads(_ names: Set<String>) { failedReads = names }
    func pushMode(_ mode: TourPro3Sound.ListeningMode, generation: UInt64 = 1) throws {
        self.mode = mode
        mailbox?.enqueue(.data(.control, try RaceFrame(kind: .notification, id: 0x0901,
                                                      payload: Data([5, 0, 0, mode.rawValue, 7, 0])).encoded()))
    }
    func perform(_ request: OperationRequest) async throws -> OperationReply {
        names.append(request.name)
        if request.name == "earbud-firmware", let readGate { try await readGate.wait() }
        if failedReads.contains(request.name) { throw LinkError.timedOut }
        let id: UInt16
        let payload: [UInt8]
        switch request.name {
        case "earbud-firmware": id = 0x1C07; payload = [0, 0, 6] + Array("v6.0.1".utf8)
        case "case-firmware": id = 0x000F; payload = [0] + Array("5.7.0".utf8)
        case "listening-mode":
            let frame = RaceFrame(kind: .response, id: 0x0901,
                                  payload: Data([5, 0, 0, mode.rawValue, 7, 0, mode == .anc ? 5 : 6]))
            mailbox?.enqueue(.data(.control, try frame.encoded()))
            return .response([frame])
        case "battery-agent": id = 0x0CD6; payload = [0, 0, 45]
        case "battery-partner": id = 0x0CD6; payload = [0, 1, 49]
        case "test-ambient", "test-anc":
            if let writeGate { try await writeGate.wait() }
            mode = request.name == "test-ambient" ? .ambient : .anc
            try pushMode(mode)
            if failMode { throw ModeTestError.unconfirmed }
            return .confirmedMode(mode, changed: true)
        default: throw SessionFailure.unsupported
        }
        let frames = [RaceFrame(kind: .response, id: id, payload: Data([0])),
                      RaceFrame(kind: .notification, id: id, payload: Data(payload))]
        for frame in frames { mailbox?.enqueue(.data(.control, try frame.encoded())) }
        return .response(frames)
    }
}

private actor FailingOpenConnection: SessionConnection {
    nonisolated let generation: UInt64 = 1
    var isActive: Bool { false }
    private(set) var stops = 0
    func start() throws { throw LinkError.io(-1) }
    func perform(_ request: OperationRequest) throws -> OperationReply { throw LinkError.disconnected }
    func stop() { stops += 1 }
}
private actor AttemptCounter {
    private(set) var count = 0
    private(set) var permits: [AcquisitionPermit] = []
    func make(_ permit: AcquisitionPermit) -> FailingOpenConnection {
        count += 1; permits.append(permit)
        return FailingOpenConnection()
    }
}

@Suite struct SessionEngineTests {
    private let selected = DeviceReference(address: "11:22:33:44:55:66", name: "JBL Tour Pro 3")
    private func settle(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        try await withDeadline(.seconds(3)) {
            while !(await predicate()) {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }

    @Test func singleStoreAndConfirmedReads() async throws {
        let session = DeviceSession()
        _ = try await session.attachStore()
        await #expect(throws: SessionFailure.streamAlreadyAttached) { try await session.attachStore() }
        await session.selectDevice(selected)
        let backend = ReplaySessionConnection()
        try await session.acquire(using: backend)
        let snapshot = await session.currentSnapshot()
        #expect(snapshot.phase == .telemetryReady)
        #expect(snapshot.earbudFirmware == "6.0.1")
        #expect(snapshot.caseFirmware == "5.7.0")
        #expect(snapshot.confirmed[.listeningMode]?.value == .mode(.anc))
        #expect(snapshot.batteryAgent == .level(percent: 45, charging: false, observedAt: snapshotBatteryDate(snapshot)))
        #expect(snapshot.capabilities[.equalizer] == .unknown)
        await session.releaseControls()
        let stale = await session.currentSnapshot()
        #expect(stale.confirmed[.listeningMode]?.isStale == true)
        #expect(stale.batteryReadingsStale)
    }

    private func snapshotBatteryDate(_ snapshot: DeviceSnapshot) -> Date {
        if case .level(_, _, let date) = snapshot.batteryAgent { return date }
        return .distantPast
    }

    @Test func unsupportedCommandEmitsNoOperationAndDefaultWritesStayDisabled() async throws {
        let backend = ReplaySessionConnection()
        let session = DeviceSession()
        await session.selectDevice(selected)
        try await session.acquire(using: backend)
        let before = await backend.names.count
        await #expect(throws: SessionFailure.unsupported) {
            try await session.set(.setting(feature: .equalizer, value: .integer(1)))
        }
        await #expect(throws: SessionFailure.unsupported) { try await session.set(.listeningMode(.ambient)) }
        await #expect(throws: SessionFailure.unsupported) { try await session.perform(.findMyBuds) }
        #expect(await backend.names.count == before)
        await session.releaseControls()
    }

    @Test func coalescesEditsAndKeepsFinalIntent() async throws {
        let time = TestSessionClock()
        let backend = ReplaySessionConnection()
        let session = DeviceSession(clock: time.clock, allowCapturedModeChanges: true)
        await session.setVisibility(true)
        await session.selectDevice(selected); try await session.acquire(using: backend)
        let first = Task { try await session.set(.listeningMode(.ambient)) }
        try await settle { time.hasSleeper(within: .milliseconds(150)) }
        let second = Task { try await session.set(.listeningMode(.anc)) }
        try await settle { await session.currentSnapshot().intents[.listeningMode]?.value == .mode(.anc) }
        let third = Task { try await session.set(.listeningMode(.ambient)) }
        try await settle { await session.currentSnapshot().intents[.listeningMode]?.value == .mode(.ambient) }
        time.advance(.milliseconds(151))
        #expect(try await third.value == .confirmed)
        if case .superseded = try await first.value {} else { Issue.record("First edit was not superseded") }
        if case .superseded = try await second.value {} else { Issue.record("Second edit was not superseded") }
        #expect(await backend.names.filter { $0.hasPrefix("test-") } == ["test-ambient"])
        #expect(await session.currentSnapshot().intents.isEmpty)
        await session.releaseControls()
    }

    @Test func cancellationRetiresInFlightBeforeNextCommand() async throws {
        let scheduler = Scheduler(clock: .live)
        let gate = PendingSlot<Void>()
        let entered = PendingSlot<Void>()
        let secondEntered = PendingSlot<Void>()
        let first = Task {
            try await scheduler.submit {
                entered.finish(.success(()))
                try await gate.wait()
                return .confirmedMode(.ambient, changed: true)
            }
        }
        try await entered.wait()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        let second = Task {
            try await scheduler.submit {
                secondEntered.finish(.success(()))
                return .confirmedMode(.anc, changed: true)
            }
        }
        // Only the explicit gate can retire the first transaction.
        gate.finish(.success(()))
        try await secondEntered.wait()
        _ = try await second.value
        await scheduler.close()
    }

    @Test func failedOldIntentDoesNotRemoveNewerIntentOrPush() async throws {
        let time = TestSessionClock()
        let backend = ReplaySessionConnection(events: true)
        let session = DeviceSession(clock: time.clock, allowCapturedModeChanges: true)
        await session.setVisibility(true)
        await session.selectDevice(selected); try await session.acquire(using: backend)
        let gate = PendingSlot<Void>()
        await backend.setWriteGate(gate); await backend.setFailMode(true)
        let first = Task { try await session.set(.listeningMode(.ambient)) }
        try await settle { time.hasSleeper(within: .milliseconds(150)) }
        time.advance(.milliseconds(151))
        try await settle { await backend.names.contains("test-ambient") }
        let second = Task { try await session.set(.listeningMode(.anc)) }
        try await settle { await session.currentSnapshot().intents[.listeningMode]?.value == .mode(.anc) }
        gate.finish(.success(()))
        #expect(try await first.value == .unconfirmed)
        #expect(await session.currentSnapshot().intents[.listeningMode]?.value == .mode(.anc))
        try await settle { await session.currentSnapshot().confirmed[.listeningMode]?.value == .mode(.ambient) }
        second.cancel()
        _ = await second.result
        await session.releaseControls()
    }

    @Test func threeFailuresDisableAutomaticReadsUntilRetry() async throws {
        let backend = ReplaySessionConnection()
        await backend.failReads(["listening-mode"])
        let session = DeviceSession()
        await session.selectDevice(selected); try await session.acquire(using: backend)
        await session.refresh(); await session.refresh()
        #expect(await session.currentSnapshot().capabilities[.listeningMode] == .indeterminate)
        let attempts = await backend.names.filter { $0 == "listening-mode" }.count
        await session.refresh()
        #expect(await backend.names.filter { $0 == "listening-mode" }.count == attempts)
        await session.retry(); await session.refresh()
        #expect(await backend.names.filter { $0 == "listening-mode" }.count == attempts + 1)
        await session.releaseControls()
    }

    @Test func orderedPushesUpdateStateWithoutPendingTransaction() async throws {
        let backend = ReplaySessionConnection(events: true)
        let session = DeviceSession()
        await session.selectDevice(selected); try await session.acquire(using: backend)
        try await backend.pushMode(.ambient)
        try await settle { await session.currentSnapshot().confirmed[.listeningMode]?.value == .mode(.ambient) }
        try await backend.pushMode(.anc)
        try await settle { await session.currentSnapshot().confirmed[.listeningMode]?.value == .mode(.anc) }
        await session.releaseControls()
        // The old stream cannot publish into the next device generation.
        await session.selectDevice(nil)
        try await backend.pushMode(.ambient)
        #expect(await session.currentSnapshot().confirmed.isEmpty)
    }

    @Test func idleReleaseAndSleepDoNotResumeWorkflowOrReconnect() async throws {
        let time = TestSessionClock()
        let backend = ReplaySessionConnection()
        let session = DeviceSession(clock: time.clock)
        await session.selectDevice(selected); try await session.acquire(using: backend)
        try await settle { time.sleeperCount >= 1 }
        time.advance(.seconds(30))
        try await settle { await session.currentSnapshot().phase == .idle }
        #expect(await backend.stops == 1)
        await session.setAwake(false)
        await session.setAwake(true)
        #expect(await session.currentSnapshot().phase == .idle)
        #expect(await backend.stops == 1)
    }

    @Test func workflowLeaseRejectsOrdinaryWorkAndReleasesAfterRetirement() async throws {
        let scheduler = Scheduler(clock: .live)
        let lease = try await scheduler.beginWorkflow(.findMyBuds)
        await #expect(throws: SessionFailure.busy(.findMyBuds)) {
            try await scheduler.submit { .confirmedMode(.anc, changed: false) }
        }
        let gate = PendingSlot<Void>()
        let entered = PendingSlot<Void>()
        let step = Task {
            try await scheduler.submit(workflow: lease) {
                entered.finish(.success(())); try await gate.wait()
                return .confirmedMode(.anc, changed: false)
            }
        }
        try await entered.wait()
        await #expect(throws: SessionFailure.busy(.findMyBuds)) { try await scheduler.endWorkflow(lease) }
        gate.finish(.success(())); _ = try await step.value
        try await scheduler.endWorkflow(lease)
        _ = try await scheduler.submit { .confirmedMode(.anc, changed: false) }
        await scheduler.close()
    }

    @Test func failedMandatoryReadNeverClaimsTelemetryReady() async throws {
        let backend = ReplaySessionConnection()
        await backend.failReads(["listening-mode"])
        let session = DeviceSession()
        await session.selectDevice(selected); try await session.acquire(using: backend)
        #expect(await session.currentSnapshot().phase == .controlsUnavailable)
        #expect(await session.currentSnapshot().confirmed[.listeningMode] == nil)
        #expect(await session.currentSnapshot().capabilities[.listeningMode] == .temporarilyUnavailable)
        await session.releaseControls()
    }

    @Test func oldRefreshCannotSkipOrClearNewGenerationBootstrap() async throws {
        let session = DeviceSession()
        await session.selectDevice(selected)
        let old = ReplaySessionConnection()
        let gate = PendingSlot<Void>()
        await old.setReadGate(gate)
        let oldAcquire = Task { try await session.acquire(using: old) }
        try await settle { await old.names.contains("earbud-firmware") }
        await session.releaseControls()
        let new = ReplaySessionConnection()
        try await session.acquire(using: new)
        #expect(await new.names.count == 5)
        #expect(await session.currentSnapshot().phase == .telemetryReady)
        gate.finish(.success(()))
        await #expect(throws: SessionFailure.notConnected) { try await oldAcquire.value }
        #expect(await session.currentSnapshot().phase == .telemetryReady)
        #expect(await session.currentSnapshot().isRefreshing == false)
        await session.releaseControls()
    }

    @Test func exclusiveWorkflowMergesRefreshAndRejectsUndeclaredSteps() async throws {
        let backend = ReplaySessionConnection()
        let session = DeviceSession(allowCapturedModeChanges: true)
        await session.selectDevice(selected); try await session.acquire(using: backend)
        let before = await backend.names.count
        let plan = WorkflowPlan(kind: .findMyBuds, steps: ["battery-agent"], stop: nil)
        try await session.withExclusiveSession(plan) { lease in
            await #expect(throws: SessionFailure.busy(.findMyBuds)) { try await session.set(.listeningMode(.ambient)) }
            await session.refresh(); await session.refresh()
            #expect(await backend.names.count == before)
            await #expect(throws: SessionFailure.unsupported) {
                try await session.perform(OperationRequest("test-ambient"), in: lease)
            }
            _ = try await session.perform(OperationRequest("battery-agent"), in: lease)
        }
        #expect(await backend.names.count == before + 1 + 5)
        #expect(await session.currentSnapshot().workflow == nil)
        await #expect(throws: SessionFailure.unsupported) {
            try await session.withExclusiveSession(kind: .findMyBuds) { _ in () }
        }
        await session.releaseControls()
    }

    @Test func retryBudgetAndRevocationNeverAcquireWithACLDown() async throws {
        let time = TestSessionClock()
        let session = DeviceSession(clock: time.clock)
        await session.selectDevice(selected)
        let attempts = AttemptCounter()
        let coordinator = DiscoveryCoordinator(session: session, clock: time.clock) { _, permit in
            await attempts.make(permit)
        }
        var context = AcquisitionContext(selectedAndPaired: true, classicConnected: false, controlNeeded: true)
        await coordinator.update(context, restart: .classicConnected)
        await coordinator.update(context, restart: .retry)
        #expect(await attempts.count == 0)
        context.classicConnected = true
        await coordinator.update(context, restart: .classicConnected)
        try await settle { await attempts.count == 1 }
        for (delay, count) in [(1, 2), (2, 3), (4, 4)] {
            try await settle { time.sleeperCount >= 1 }
            time.advance(.seconds(delay))
            try await settle { await attempts.count == count }
        }
        try await settle { await coordinator.phase == .unavailable }
        time.advance(.seconds(100))
        #expect(await attempts.count == 4)
        await coordinator.update(context, restart: .retry)
        try await settle { await attempts.count == 5 }
        context.classicConnected = false
        await coordinator.update(context)
        time.advance(.seconds(100))
        #expect(await attempts.count == 5)
        #expect(await attempts.permits.allSatisfy { !$0.allowsAcquisition })
    }

    @Test func lateFactoryAfterDisconnectClosesWithoutOpening() async throws {
        let session = DeviceSession()
        await session.selectDevice(selected)
        let candidate = ReplaySessionConnection()
        let entered = PendingSlot<Void>()
        let gate = PendingSlot<Void>()
        let coordinator = DiscoveryCoordinator(session: session) { _, _ in
            entered.finish(.success(())); try await gate.wait()
            return candidate
        }
        var context = AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true)
        await coordinator.update(context, restart: .classicConnected)
        try await entered.wait()
        context.classicConnected = false
        await coordinator.update(context)
        gate.finish(.success(()))
        // A cancellation-aware factory may return no candidate at all. Either
        // way, not one captured read is allowed after the ACL goes down.
        #expect(await candidate.names.isEmpty)
        #expect(await candidate.isActive == false)
    }

    @Test func readinessIncludesOrderedIngressWithoutTransientMissingValues() async throws {
        let backend = ReplaySessionConnection(events: true)
        let session = DeviceSession()
        await session.selectDevice(selected); try await session.acquire(using: backend)
        let ready = await session.currentSnapshot()
        #expect(ready.phase == .telemetryReady)
        #expect(ready.earbudFirmware == "6.0.1")
        #expect(ready.caseFirmware == "5.7.0")
        #expect(ready.confirmed[.listeningMode]?.value == .mode(.anc))
        #expect(!ready.batteryAgentStale && !ready.batteryPartnerStale)
        #expect(ready.caseBattery == .unknown)
        #expect(ready.caseBatteryStale)
        await session.releaseControls()
    }

    @Test func cancelledWorkflowRetiresThenRunsOnlyDeclaredAbort() async throws {
        let backend = ReplaySessionConnection()
        let session = DeviceSession(allowCapturedModeChanges: true)
        await session.selectDevice(selected); try await session.acquire(using: backend)
        let gate = PendingSlot<Void>()
        await backend.setWriteGate(gate)
        let plan = WorkflowPlan(kind: .findMyBuds, steps: ["test-ambient", "listening-mode"], stop: "listening-mode")
        let workflow = Task {
            try await session.withExclusiveSession(plan) { lease in
                _ = try await session.perform(OperationRequest("test-ambient"), in: lease)
            }
        }
        try await settle { await backend.names.last == "test-ambient" }
        workflow.cancel()
        await #expect(throws: SessionFailure.busy(.findMyBuds)) { try await session.set(.listeningMode(.anc)) }
        gate.finish(.success(()))
        await #expect(throws: CancellationError.self) { try await workflow.value }
        #expect(await backend.names.suffix(2) == ["test-ambient", "listening-mode"])
        #expect(await session.currentSnapshot().workflow == nil)
        await session.releaseControls()
    }

    @Test func cancellingOnlyQueuedWorkReleasesIdleWaiter() async throws {
        let time = TestSessionClock()
        let scheduler = Scheduler(clock: time.clock)
        let queued = Task {
            try await scheduler.submit(feature: .listeningMode, debounce: .seconds(10)) {
                Issue.record("Cancelled queued operation executed")
                return .confirmedMode(.anc, changed: false)
            }
        }
        try await settle { time.sleeperCount == 1 }
        let idle = Task { try await scheduler.waitUntilIdle() }
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        try await withDeadline(.seconds(2)) { try await idle.value }
        await scheduler.close()
    }

    @Test func cancelledRefreshDoesNotDegradeCapabilitiesOrReadRemainingFields() async throws {
        let backend = ReplaySessionConnection()
        let session = DeviceSession()
        await session.selectDevice(selected); try await session.acquire(using: backend)
        let before = await session.currentSnapshot()
        let gate = PendingSlot<Void>()
        await backend.setReadGate(gate)
        let refresh = Task { await session.refresh() }
        try await settle { await backend.names.count == 6 }
        refresh.cancel(); await refresh.value
        let after = await session.currentSnapshot()
        #expect(after.capabilities == before.capabilities)
        #expect(after.errors == before.errors)
        #expect(after.phase == .telemetryReady)
        #expect(after.isRefreshing == false)
        #expect(await backend.names.count == 6)
        gate.finish(.success(()))
        await session.releaseControls()
    }

    @Test func preCancelledAcquisitionDoesNotOpenOrPublishPendingState() async throws {
        let backend = ReplaySessionConnection()
        let session = DeviceSession()
        await session.selectDevice(selected)
        let acquire = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await session.acquire(using: backend)
        }
        await #expect(throws: CancellationError.self) { try await acquire.value }
        #expect(await backend.isActive == false)
        #expect(await backend.names.isEmpty)
        #expect(await session.currentSnapshot().phase == .idle)
    }

    @Test func refreshDoesNotDowngradeVerifiedWriteAvailability() async throws {
        let backend = ReplaySessionConnection()
        let session = DeviceSession(allowCapturedModeChanges: true)
        await session.selectDevice(selected); try await session.acquire(using: backend)
        #expect(try await session.set(.listeningMode(.ambient)) == .confirmed)
        #expect(await session.currentSnapshot().capabilities[.listeningMode] == .supported)
        await session.refresh()
        #expect(await session.currentSnapshot().capabilities[.listeningMode] == .supported)
        await session.releaseControls()
    }

    @Test func visiblePollingReadsOnlyBatteryAt120SecondsAndStopsWhenHidden() async throws {
        let time = TestSessionClock()
        let backend = ReplaySessionConnection()
        let session = DeviceSession(clock: time.clock)
        await session.setVisibility(true)
        await session.selectDevice(selected); try await session.acquire(using: backend)
        try await settle { time.sleeperCount == 1 }
        time.advance(.seconds(119))
        #expect(await backend.names.count == 5)
        time.advance(.seconds(1))
        try await settle { await backend.names.count == 7 }
        #expect(await backend.names.suffix(2) == ["battery-agent", "battery-partner"])
        try await settle { time.sleeperCount == 1 }
        await session.setVisibility(false)
        try await settle { time.hasSleeper(within: .seconds(30)) }
        time.advance(.seconds(120))
        try await settle { await backend.stops == 1 }
        #expect(await backend.names.count == 7)
    }

    @Test func deinitializingStoreClosesExternallyRetainedBackend() async throws {
        let backend = ReplaySessionConnection()
        var session: DeviceSession? = DeviceSession()
        await session!.selectDevice(selected); try await session!.acquire(using: backend)
        session = nil
        try await settle { await backend.stops == 1 }
        #expect(await backend.isActive == false)
    }

    @Test func batteryPollRespectsFreshManualReadBudget() async throws {
        let time = TestSessionClock()
        let backend = ReplaySessionConnection()
        let session = DeviceSession(clock: time.clock)
        await session.setVisibility(true)
        await session.selectDevice(selected); try await session.acquire(using: backend)
        try await settle { time.sleeperCount == 1 }
        time.advance(.seconds(119))
        await session.refresh()
        #expect(await backend.names.count == 10)
        // The original timer can wake, but a one-second-old reading must not
        // trigger a new automatic battery transaction.
        time.advance(.seconds(1))
        #expect(await backend.names.count == 10)
        await session.releaseControls()
    }
}
