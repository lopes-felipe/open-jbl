import Foundation

/// The only operation boundary the state store uses. Tests can supply a replay
/// connection; production uses GuardedSession with its unchanged catalog policy.
public protocol SessionConnection: Sendable {
    var generation: UInt64 { get async }
    var isActive: Bool { get async }
    func start() async throws
    func perform(_ request: OperationRequest) async throws -> OperationReply
    func stop() async
    func stateEvents() async throws -> OrderedMailbox?
}
public extension SessionConnection {
    func stateEvents() async throws -> OrderedMailbox? { nil }
}
extension GuardedSession: SessionConnection {
    public func stateEvents() async throws -> OrderedMailbox? { try attachStateEvents() }
}

/// Sole state owner. Acquisition is explicit: this actor never pairs, pages,
/// guesses a transport, restores settings, or opens a link from cached state.
public actor DeviceSession {
    private var snapshot = DeviceSnapshot()
    private let clock: SessionClock
    private var store: AsyncStream<DeviceSnapshot>.Continuation?
    private var storeAttached = false
    private var connection: (any SessionConnection)?
    private var scheduler: Scheduler
    private var connectionEpoch: UInt64 = 0
    private var retiringConnections = 0
    private var events: Task<Void, Never>?
    private var eventStreamAttached = false
    private var stateMailbox: OrderedMailbox?
    private var processedSequence: UInt64 = 0
    private var ingressWaiters: [(UUID, UInt64, PendingSlot<Void>)] = []
    private var idle: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var pollingEpoch: UInt64?
    private var batteryObservedAt: [String: Duration] = [:]
    private var visible = false
    private var awake = true
    private var refreshEpoch: UInt64?
    private var refreshRequested = false
    private var bootstrapVerified = false
    private var recovery = RecoveryBudget()
    private let capturedModeChangesEnabled: Bool
    private var activeWorkflow: (lease: WorkflowLease, plan: WorkflowPlan, epoch: UInt64)?
    private var workflowCleanup: (id: UUID, completion: PendingSlot<Void>)?

    /// This opt-in enables only the two reviewed M1 mode operations, never
    /// uncaptured features. The default leaves normal app controls read-only
    /// until integration/hardware acceptance explicitly promotes them.
    public init(clock: SessionClock = .live, allowCapturedModeChanges: Bool = false) {
        self.clock = clock
        self.scheduler = Scheduler(clock: clock)
        capturedModeChangesEnabled = allowCapturedModeChanges
    }
    deinit {
        events?.cancel(); idle?.cancel(); polling?.cancel(); store?.finish()
        let connection = connection
        let scheduler = scheduler
        Task { await scheduler.close(); await connection?.stop() }
    }

    public func attachStore() throws -> AsyncStream<DeviceSnapshot> {
        guard !storeAttached else { throw SessionFailure.streamAlreadyAttached }
        storeAttached = true
        let (stream, continuation) = AsyncStream<DeviceSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        store = continuation
        continuation.yield(snapshot)
        return stream
    }
    public func currentSnapshot() -> DeviceSnapshot { snapshot }
    private func publish() { store?.yield(snapshot) }

    public func selectDevice(_ device: DeviceReference?) async {
        guard snapshot.selectedDevice != device else { return }
        await prepareToRelease()
        let nextEpoch = connectionEpoch &+ 1
        await invalidate(phase: .idle)
        guard connectionEpoch == nextEpoch else { return }
        snapshot = DeviceSnapshot()
        snapshot.selectedDevice = device
        snapshot.generation = connectionEpoch
        publish()
    }

    public func acquire(using candidate: any SessionConnection) async throws {
        try Task.checkCancellation()
        guard awake else { throw SessionFailure.sleeping }
        guard snapshot.selectedDevice?.name == ModelCatalog.tourPro3.name else { throw SessionFailure.unsupported }
        // Do not let a second open interleave with an acquisition in progress.
        guard connection == nil, retiringConnections == 0 else { throw PolicyError.busy }
        connectionEpoch &+= 1
        let epoch = connectionEpoch
        connection = candidate
        scheduler = Scheduler(clock: clock)
        snapshot.phase = .connecting
        do {
            let transportGeneration = await candidate.generation
            try Task.checkCancellation()
            guard epoch == connectionEpoch else { throw SessionFailure.staleGeneration }
            snapshot.generation = transportGeneration
            publish()
            if let mailbox = try await candidate.stateEvents() {
                guard epoch == connectionEpoch else { await candidate.stop(); throw SessionFailure.staleGeneration }
                eventStreamAttached = true
                stateMailbox = mailbox
                processedSequence = 0
                events = Task { [weak self] in
                    do {
                        while let event = try await mailbox.next() {
                            await self?.ingest(event, epoch: epoch)
                        }
                    } catch { await self?.connectionEnded(epoch: epoch) }
                }
            }
            try await candidate.start()
            try Task.checkCancellation()
            guard epoch == connectionEpoch, awake else {
                await candidate.stop(); throw SessionFailure.staleGeneration
            }
            await refresh()
            try Task.checkCancellation()
            guard epoch == connectionEpoch, await candidate.isActive else {
                throw SessionFailure.notConnected
            }
            // EQ has no captured read yet, so this is deliberately not the v1
            // ready state. Mandatory captured telemetry must still all pass.
            snapshot.phase = bootstrapVerified ? .telemetryReady : .controlsUnavailable
            publish()
            updateIdleTimer()
            updatePolling()
        } catch {
            if epoch == connectionEpoch { await invalidate(phase: .controlsUnavailable) }
            else { await candidate.stop() }
            throw error
        }
    }

    public func set(_ command: DeviceCommand) async throws -> ChangeOutcome {
        // Fail unknown feature requests without consulting a connection/encoder.
        guard case .listeningMode(let mode) = command else { throw SessionFailure.unsupported }
        guard capturedModeChangesEnabled else { throw SessionFailure.unsupported }
        try Task.checkCancellation()
        if let workflow = snapshot.workflow { throw SessionFailure.busy(workflow) }
        let name = mode == .anc ? "test-anc" : "test-ambient"
        guard let connection, snapshot.phase == .ready || snapshot.phase == .telemetryReady else {
            throw SessionFailure.notConnected
        }
        let key = budgetKey(name)
        guard recovery.permits(key) else { throw SessionFailure.indeterminate }
        let epoch = connectionEpoch
        let id = UUID()
        snapshot.intents[command.feature] = DeviceIntent(id: id, value: command.value, status: .pending)
        snapshot.errors.removeValue(forKey: command.feature)
        publish()
        do {
            let reply = try await scheduler.submit(id: id, feature: command.feature, debounce: .milliseconds(150)) {
                // GuardedSession repeats identity, firmware, precondition and
                // catalog checks at actual dispatch, after the debounce.
                try await self.dispatchSetting(name, feature: command.feature, epoch: epoch, connection: connection)
            }
            guard epoch == connectionEpoch else { throw SessionFailure.staleGeneration }
            switch reply {
            case .superseded(let successor): return .superseded(by: successor)
            case .reply(let value):
                guard case .confirmedMode(let confirmed, _) = value, confirmed == mode else {
                    throw SessionFailure.unconfirmed
                }
                if eventStreamAttached {
                    try await synchronizeIngress(epoch: epoch)
                } else { observe(value) }
                guard epoch == connectionEpoch else { throw SessionFailure.staleGeneration }
                recovery.succeeded(key)
                snapshot.capabilities[command.feature] = .supported
                if snapshot.intents[command.feature]?.id == id { snapshot.intents.removeValue(forKey: command.feature) }
                publish()
                return .confirmed
            }
        } catch {
            // A protocol failure may close the state stream before this caller
            // resumes. Its recovery budget still belongs to this app session,
            // even though teardown has already advanced the connection epoch.
            let unresolved = isRecoveryFailure(error)
            let permits = unresolved ? recovery.recordFailure(key) : recovery.permits(key)
            let unconfirmed = error as? SessionFailure == .unconfirmed ||
                error as? ModeTestError == .unconfirmed
            if epoch == connectionEpoch {
                if snapshot.intents[command.feature]?.id == id {
                    if unconfirmed { snapshot.intents[command.feature]?.status = .unconfirmed }
                    else { snapshot.intents.removeValue(forKey: command.feature) }
                }
                if error is CancellationError {
                    snapshot.errors[command.feature] = .cancelled
                } else {
                    snapshot.capabilities[command.feature] = permits ? .temporarilyUnavailable : .indeterminate
                    snapshot.errors[command.feature] = unconfirmed ? .unconfirmed : (permits ? .failed : .indeterminate)
                }
                publish()
            } else if !permits, snapshot.selectedDevice?.name == ModelCatalog.tourPro3.name {
                snapshot.capabilities[command.feature] = .indeterminate
                snapshot.errors[command.feature] = .indeterminate
                publish()
            }
            if unconfirmed { return .unconfirmed }
            throw error
        }
    }

    public func perform(_ action: DeviceAction) async throws -> ActionOutcome {
        // No captured safe start/stop contract exists. A UI cannot promote it.
        throw SessionFailure.unsupported
    }

    public func withExclusiveSession<Value: Sendable>(
        kind: WorkflowKind, _ body: @Sendable (WorkflowLease) async throws -> Value
    ) async throws -> Value {
        guard let plan = WorkflowPlan.captured(kind) else { throw SessionFailure.unsupported }
        return try await withExclusiveSession(plan, body)
    }

    // Internal source-defined plans also let replay tests exercise lease safety
    // without pretending an uncaptured production workflow is available.
    func withExclusiveSession<Value: Sendable>(
        _ plan: WorkflowPlan, _ body: @Sendable (WorkflowLease) async throws -> Value
    ) async throws -> Value {
        guard connection != nil else { throw SessionFailure.notConnected }
        try Task.checkCancellation()
        if let kind = snapshot.workflow { throw SessionFailure.busy(kind) }
        guard refreshEpoch == nil, pollingEpoch == nil else { throw PolicyError.busy }
        guard plan.steps.allSatisfy({ OperationCatalog.production[$0] != nil }),
              plan.stop.map({ plan.steps.contains($0) }) ?? true else { throw SessionFailure.unsupported }
        let epoch = connectionEpoch
        // Reserve before awaiting the scheduler lease to block actor reentrancy.
        snapshot.workflow = plan.kind
        idle?.cancel(); idle = nil
        polling?.cancel(); polling = nil
        publish()
        let scheduler = scheduler
        let lease: WorkflowLease
        do {
            let id = try await scheduler.beginWorkflow(plan.kind)
            guard epoch == connectionEpoch else { throw SessionFailure.staleGeneration }
            lease = WorkflowLease(kind: plan.kind, id: id)
            activeWorkflow = (lease, plan, epoch)
        } catch {
            if epoch == connectionEpoch { snapshot.workflow = nil; publish(); updateIdleTimer() }
            throw error
        }
        do {
            let result = try await body(lease)
            try await finishWorkflow(lease, epoch: epoch, scheduler: scheduler, abort: false)
            return result
        } catch {
            // Cleanup runs in a non-cancelled task, while the original workflow
            // stays busy until its current fragment retires or the link closes.
            let cleanup = Task {
                try await self.finishWorkflow(lease, epoch: epoch, scheduler: scheduler, abort: true)
            }
            _ = await cleanup.result
            throw error
        }
    }

    public func perform(_ request: OperationRequest, in lease: WorkflowLease) async throws -> OperationReply {
        guard let workflow = activeWorkflow, workflow.lease == lease,
              workflow.epoch == connectionEpoch, workflow.plan.steps.contains(request.name),
              let connection else { throw SessionFailure.unsupported }
        if workflowCleanup != nil, request.name != workflow.plan.stop { throw CancellationError() }
        let epoch = connectionEpoch
        let result = try await scheduler.submit(
            lane: request.name == workflow.plan.stop ? .priority : .normal, workflow: lease.id
        ) { try await connection.perform(request) }
        guard epoch == connectionEpoch else { throw SessionFailure.staleGeneration }
        guard case .reply(let reply) = result else { throw SessionFailure.failed }
        if eventStreamAttached { try await synchronizeIngress(epoch: epoch) }
        else { observe(reply); publish() }
        return reply
    }

    private func finishWorkflow(_ lease: WorkflowLease, epoch: UInt64, scheduler: Scheduler,
                                abort: Bool, refreshAfter: Bool = true) async throws {
        guard epoch == connectionEpoch, let workflow = activeWorkflow, workflow.lease == lease else { return }
        if let cleanup = workflowCleanup, cleanup.id == lease.id {
            try await cleanup.completion.wait()
            return
        }
        let completion = PendingSlot<Void>()
        workflowCleanup = (lease.id, completion)
        defer { if workflowCleanup?.id == lease.id { workflowCleanup = nil } }
        do {
            try await withDeadline(.seconds(10)) {
                // Retire any cancelled step before appending its declared abort.
                if abort { await scheduler.cancelQueued(workflow: lease.id) }
                try await scheduler.waitUntilIdle()
                if abort, let stop = workflow.plan.stop {
                    _ = try await self.perform(OperationRequest(stop), in: lease)
                }
                try await scheduler.waitUntilIdle()
                try await scheduler.endWorkflow(lease.id)
            }
        } catch {
            if epoch == connectionEpoch { await invalidate(phase: .controlsUnavailable) }
            completion.finish(.failure(error))
            throw error
        }
        guard epoch == connectionEpoch else {
            completion.finish(.failure(SessionFailure.staleGeneration))
            return
        }
        activeWorkflow = nil; snapshot.workflow = nil
        completion.finish(.success(()))
        publish()
        updateIdleTimer()
        updatePolling()
        if refreshAfter, refreshRequested { await refresh() }
    }

    private func dispatchSetting(_ name: String, feature: FeatureKey, epoch: UInt64,
                                 connection: any SessionConnection) async throws -> OperationReply {
        guard epoch == connectionEpoch, awake else { throw SessionFailure.staleGeneration }
        if let workflow = snapshot.workflow { throw SessionFailure.busy(workflow) }
        guard snapshot.capabilities[feature] != .indeterminate else { throw SessionFailure.indeterminate }
        guard snapshot.capabilities[feature] != .unsupported else { throw SessionFailure.unsupported }
        return try await connection.perform(OperationRequest(name))
    }

    public func refresh() async {
        guard connection != nil else { return }
        guard !Task.isCancelled else { return }
        if refreshEpoch == connectionEpoch || pollingEpoch == connectionEpoch || snapshot.workflow != nil {
            refreshRequested = true; return
        }
        let epoch = connectionEpoch
        refreshEpoch = epoch
        snapshot.isRefreshing = true; publish()
        var cancelled = false
        repeat {
            refreshRequested = false
            var verified: Set<String> = []
            let operations: [(String, FeatureKey)] = [
                ("earbud-firmware", .firmware), ("case-firmware", .firmware),
                ("listening-mode", .listeningMode),
                ("battery-agent", .battery), ("battery-partner", .battery)
            ]
            for (name, feature) in operations {
                if Task.isCancelled { cancelled = true; break }
                guard epoch == connectionEpoch, let connection else { break }
                let key = budgetKey(name)
                guard recovery.permits(key) else { continue }
                do {
                    try await executeRead(name, feature: feature, key: key, connection: connection, epoch: epoch)
                    verified.insert(name)
                } catch {
                    if error is CancellationError { cancelled = true; break }
                    recordReadFailure(error, feature: feature, key: key, epoch: epoch)
                    guard epoch == connectionEpoch else { break }
                    if !(await connection.isActive) { break }
                }
            }
            if epoch == connectionEpoch, !cancelled {
                bootstrapVerified = verified.count == operations.count
                if snapshot.phase != .connecting {
                    snapshot.phase = bootstrapVerified ? .telemetryReady : .controlsUnavailable
                }
            }
        } while !cancelled && refreshRequested && epoch == connectionEpoch && snapshot.workflow == nil && connection != nil
        if epoch == connectionEpoch {
            snapshot.isRefreshing = false; publish()
            if snapshot.phase != .connecting { updatePolling() }
        }
        if refreshEpoch == epoch { refreshEpoch = nil }
    }

    private func executeRead(_ name: String, feature: FeatureKey, key: RecoveryBudget.Key,
                             connection: any SessionConnection, epoch: UInt64) async throws {
        let result = try await scheduler.submit {
            try await connection.perform(OperationRequest(name))
        }
        guard epoch == connectionEpoch else { throw SessionFailure.staleGeneration }
        guard case .reply(let reply) = result else { throw SessionFailure.failed }
        if eventStreamAttached { try await synchronizeIngress(epoch: epoch) }
        guard epoch == connectionEpoch else { throw SessionFailure.staleGeneration }
        try validateRead(reply, operation: name)
        if !eventStreamAttached { observe(reply) }
        recovery.succeeded(key)
        if snapshot.capabilities[feature] != .indeterminate {
            if snapshot.capabilities[feature] != .supported { snapshot.capabilities[feature] = .readOnly }
            snapshot.errors.removeValue(forKey: feature)
        }
        publish()
    }

    private func recordReadFailure(_ error: any Error, feature: FeatureKey, key: RecoveryBudget.Key, epoch: UInt64) {
        guard isRecoveryFailure(error) else { return }
        let permits = recovery.recordFailure(key)
        if epoch == connectionEpoch || !permits {
            snapshot.capabilities[feature] = permits ? .temporarilyUnavailable : .indeterminate
            snapshot.errors[feature] = permits ? .failed : .indeterminate
            publish()
        }
    }

    private func isRecoveryFailure(_ error: any Error) -> Bool {
        if error is ModeTestError { return true }
        if let linkError = error as? LinkError {
            switch linkError {
            case .timedOut, .poisoned, .io, .unavailable: return true
            default: return false
            }
        }
        return error as? SessionFailure == .unconfirmed
    }

    /// Retry resets bounded capability recovery. Acquisition remains a separate
    /// explicit action, subject to the transport's existing Classic ACL guard.
    public func retry() {
        recovery.reset()
        for feature in FeatureKey.allCases where snapshot.capabilities[feature] == .indeterminate {
            snapshot.capabilities[feature] = .unknown
            snapshot.errors.removeValue(forKey: feature)
        }
        publish()
    }

    public func releaseControls() async {
        await prepareToRelease()
        await invalidate(phase: .released)
    }
    private func prepareToRelease() async {
        guard let workflow = activeWorkflow else { return }
        // A source-defined abort is attempted only after transmission retires.
        // finishWorkflow tears the channel down if the bounded cleanup fails.
        try? await finishWorkflow(workflow.lease, epoch: workflow.epoch, scheduler: scheduler,
                                  abort: true, refreshAfter: false)
    }
    public func setAwake(_ value: Bool) async {
        awake = value
        if !value { await invalidate(phase: .sleeping) }
        else if snapshot.phase == .sleeping { snapshot.phase = .idle; publish() }
        // Wake never resumes an action/workflow or opens a connection.
    }
    public func setVisibility(_ value: Bool) {
        visible = value
        updateIdleTimer()
        updatePolling()
    }

    private func updatePolling() {
        polling?.cancel(); polling = nil
        guard visible, awake, snapshot.workflow == nil, connection != nil,
              snapshot.phase == .telemetryReady || snapshot.phase == .ready else { return }
        let epoch = connectionEpoch
        let clock = clock
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(.seconds(120)) } catch { return }
                guard let self else { return }
                await self.pollBattery(epoch: epoch)
            }
        }
    }

    private func pollBattery(epoch: UInt64) async {
        guard epoch == connectionEpoch, visible, awake, snapshot.workflow == nil,
              refreshEpoch == nil, pollingEpoch == nil, !Task.isCancelled,
              let connection else { return }
        pollingEpoch = epoch
        for name in ["battery-agent", "battery-partner"] {
            guard epoch == connectionEpoch, visible, snapshot.workflow == nil, !Task.isCancelled else { break }
            if let observed = batteryObservedAt[name], clock.now() - observed < .seconds(120) { continue }
            let key = budgetKey(name)
            guard recovery.permits(key) else { continue }
            do { try await executeRead(name, feature: .battery, key: key, connection: connection, epoch: epoch) }
            catch {
                if error is CancellationError { break }
                recordReadFailure(error, feature: .battery, key: key, epoch: epoch)
                guard epoch == connectionEpoch else { break }
                if !(await connection.isActive) { break }
            }
        }
        if pollingEpoch == epoch { pollingEpoch = nil }
        if epoch == connectionEpoch, refreshRequested, !Task.isCancelled { await refresh() }
    }

    private func updateIdleTimer() {
        idle?.cancel(); idle = nil
        guard !visible, snapshot.workflow == nil, connection != nil else { return }
        let epoch = connectionEpoch
        let clock = clock
        idle = Task { [weak self] in
            do { try await clock.sleep(.seconds(30)) } catch { return }
            await self?.idleExpired(epoch: epoch)
        }
    }
    private func idleExpired(epoch: UInt64) async {
        guard epoch == connectionEpoch, !visible, snapshot.workflow == nil else { return }
        await invalidate(phase: .idle)
    }

    private func invalidate(phase: SessionPhase) async {
        connectionEpoch &+= 1
        let previous = connection
        if previous != nil { retiringConnections += 1 }
        connection = nil
        events?.cancel(); events = nil; eventStreamAttached = false
        stateMailbox = nil; processedSequence = 0
        let waiters = ingressWaiters; ingressWaiters = []
        waiters.forEach { $0.2.finish(.failure(SessionFailure.notConnected)) }
        idle?.cancel(); idle = nil
        polling?.cancel(); polling = nil; pollingEpoch = nil
        batteryObservedAt = [:]
        let previousScheduler = scheduler
        snapshot.phase = phase; snapshot.generation = connectionEpoch
        snapshot.workflow = nil; snapshot.intents = [:]; snapshot.isRefreshing = false
        activeWorkflow = nil
        workflowCleanup?.completion.finish(.failure(SessionFailure.notConnected)); workflowCleanup = nil
        refreshRequested = false
        refreshEpoch = nil; bootstrapVerified = false
        for feature in snapshot.confirmed.keys { snapshot.confirmed[feature]?.isStale = true }
        snapshot.batteryReadingsStale = true
        snapshot.batteryAgentStale = true; snapshot.batteryPartnerStale = true; snapshot.caseBatteryStale = true
        publish()
        await previousScheduler.close()
        await previous?.stop()
        if previous != nil { retiringConnections -= 1 }
    }

    private func budgetKey(_ name: String) -> RecoveryBudget.Key {
        RecoveryBudget.Key(firmware: snapshot.earbudFirmware ?? "unknown", component: "earbuds", operation: name)
    }

    private func ingest(_ event: SequencedEvent, epoch: UInt64) async {
        guard epoch == connectionEpoch, event.generation == snapshot.generation else { return }
        switch event.event {
        case .data(.control, let bytes):
            guard let frame = try? RaceFrame.exact(bytes) else {
                await invalidate(phase: .controlsUnavailable); return
            }
            observe(frame)
            publish()
        case .closed: await connectionEnded(epoch: epoch)
        default: break
        }
        guard epoch == connectionEpoch else { return }
        processedSequence = event.sequence
        let ready = ingressWaiters.filter { $0.1 <= processedSequence }
        ingressWaiters.removeAll { $0.1 <= processedSequence }
        ready.forEach { $0.2.finish(.success(())) }
    }

    /// Wait for a finite sequence watermark already queued by GuardedSession.
    /// This prevents a request continuation from clearing an intent before the
    /// authoritative readback (or a newer device push) reaches the state store.
    private func synchronizeIngress(epoch: UInt64) async throws {
        guard let mailbox = stateMailbox else { return }
        let target = mailbox.lastEnqueuedSequence
        guard processedSequence < target else { return }
        guard ingressWaiters.count < 128 else { throw LinkError.overflow }
        let id = UUID()
        let slot = PendingSlot<Void>()
        ingressWaiters.append((id, target, slot))
        defer { ingressWaiters.removeAll { $0.0 == id } }
        try await withDeadline(.seconds(2)) { try await slot.wait() }
        guard epoch == connectionEpoch else { throw SessionFailure.staleGeneration }
    }
    private func connectionEnded(epoch: UInt64) async {
        guard epoch == connectionEpoch else { return }
        await invalidate(phase: .controlsUnavailable)
    }

    private func observe(_ reply: OperationReply) {
        switch reply {
        case .response(let frames): frames.forEach { observe($0) }
        case .confirmedMode(let mode, _):
            snapshot.confirmed[.listeningMode] = ConfirmedValue(value: .mode(mode), observedAt: clock.date())
        }
    }
    private func observe(_ frame: RaceFrame) {
        if let report = TourPro3Sound.decodeListeningReadback(frame) ?? TourPro3Sound.decodeListeningReport(frame) {
            snapshot.confirmed[.listeningMode] = ConfirmedValue(value: .mode(report.mode), observedAt: clock.date())
        }
        if let report = TourPro3Telemetry.decodeFirmware(frame) {
            if report.component == .earbuds { snapshot.earbudFirmware = report.version }
            if report.component == .chargingCase { snapshot.caseFirmware = report.version }
        }
        if let report = TourPro3Telemetry.decodeBattery(frame) {
            let reading = BatteryReading.level(percent: report.percent, charging: false, observedAt: clock.date())
            switch report.component {
            case .agent:
                snapshot.batteryAgent = reading; snapshot.batteryAgentStale = false
                batteryObservedAt["battery-agent"] = clock.now()
            case .partner:
                snapshot.batteryPartner = reading; snapshot.batteryPartnerStale = false
                batteryObservedAt["battery-partner"] = clock.now()
            case .chargingCase: snapshot.caseBattery = reading; snapshot.caseBatteryStale = false
            default: break
            }
            snapshot.batteryReadingsStale = false
        }
    }
    private func validateRead(_ reply: OperationReply, operation: String) throws {
        guard case .response(let frames) = reply else { throw SessionFailure.unconfirmed }
        if operation == "listening-mode" {
            guard frames.contains(where: { TourPro3Sound.decodeListeningReadback($0) != nil }) else {
                throw SessionFailure.unconfirmed
            }
        } else {
            guard frames.contains(where: { $0.kind == .response && $0.payload == Data([0]) }) else {
                throw SessionFailure.unconfirmed
            }
            let valid: Bool
            switch operation {
            case "earbud-firmware": valid = frames.contains { TourPro3Telemetry.decodeFirmware($0)?.component == .earbuds }
            case "case-firmware": valid = frames.contains { TourPro3Telemetry.decodeFirmware($0)?.component == .chargingCase }
            case "battery-agent": valid = frames.contains { TourPro3Telemetry.decodeBattery($0)?.component == .agent }
            case "battery-partner": valid = frames.contains { TourPro3Telemetry.decodeBattery($0)?.component == .partner }
            default: valid = false
            }
            guard valid else { throw SessionFailure.unconfirmed }
        }
    }
}
