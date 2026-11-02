import Foundation

enum ScheduledReply: Sendable { case reply(OperationReply), superseded(UUID) }
enum SchedulerLane: Sendable { case normal, priority }

/// One transaction runs at a time. A cancelled caller releases its continuation,
/// but its dispatched operation retires before the next transaction can start.
/// Coalescing replaces queued work only; it never cancels an in-flight write.
actor Scheduler {
    struct Entry: Sendable {
        let id: UUID
        let feature: FeatureKey?
        let readyAt: Duration
        let lane: SchedulerLane
        let workflow: UUID?
        let execute: @Sendable () async throws -> OperationReply
        var continuation: CheckedContinuation<ScheduledReply, any Error>?
    }
    private let clock: SessionClock
    private var queue: [Entry] = []
    private var current: Entry?
    private var wake: Task<Void, Never>?
    private var closed = false
    private var lease: (id: UUID, kind: WorkflowKind)?
    private var idleWaiters: [PendingSlot<Void>] = []
    init(clock: SessionClock) { self.clock = clock }
    deinit { wake?.cancel() }

    func submit(id: UUID = UUID(), feature: FeatureKey? = nil, debounce: Duration = .zero,
                lane: SchedulerLane = .normal, workflow: UUID? = nil,
                execute: @escaping @Sendable () async throws -> OperationReply) async throws -> ScheduledReply {
        try Task.checkCancellation()
        guard !closed else { throw SessionFailure.notConnected }
        if let lease, workflow != lease.id { throw SessionFailure.busy(lease.kind) }
        guard queue.count < 128 || (feature != nil && queue.contains(where: { $0.feature == feature })) else {
            throw PolicyError.busy
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let feature, let index = queue.firstIndex(where: { $0.feature == feature }) {
                    let replaced = queue.remove(at: index)
                    replaced.continuation?.resume(returning: .superseded(id))
                }
                queue.append(Entry(id: id, feature: feature, readyAt: clock.now() + debounce,
                                   lane: lane, workflow: workflow, execute: execute, continuation: continuation))
                dispatch()
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    private func cancel(_ id: UUID) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            let entry = queue.remove(at: index)
            entry.continuation?.resume(throwing: CancellationError())
        } else if current?.id == id {
            let continuation = current?.continuation
            current?.continuation = nil
            continuation?.resume(throwing: CancellationError())
        }
        dispatch()
        signalIdle()
    }

    private func dispatch() {
        guard current == nil, !closed else { return }
        wake?.cancel(); wake = nil
        guard !queue.isEmpty else { return }
        // A workflow/heartbeat priority step bypasses queued debounce work.
        let ready = queue.indices.filter { queue[$0].readyAt <= clock.now() }
        let index = ready.first(where: { queue[$0].lane == .priority }) ?? ready.first
        guard let index else {
            let deadline = queue.map(\.readyAt).min()!
            let clock = clock
            wake = Task { [weak self] in
                do { try await clock.sleep(max(.zero, deadline - clock.now())) }
                catch { return }
                await self?.dispatch()
            }
            return
        }
        let entry = queue.remove(at: index)
        current = entry // reserve ownership before the first suspension
        Task {
            let result: Result<OperationReply, any Error>
            do { result = .success(try await entry.execute()) }
            catch { result = .failure(error) }
            self.finish(entry.id, result)
        }
    }

    private func finish(_ id: UUID, _ result: Result<OperationReply, any Error>) {
        guard current?.id == id else { return }
        let continuation = current?.continuation
        current = nil
        continuation?.resume(with: result.map { .reply($0) })
        dispatch()
        signalIdle()
    }

    private func signalIdle() {
        guard current == nil, queue.isEmpty else { return }
        let waiters = idleWaiters; idleWaiters = []
        waiters.forEach { $0.finish(.success(())) }
    }

    func cancelQueued(workflow: UUID) {
        let cancelled = queue.filter { $0.workflow == workflow }
        queue.removeAll { $0.workflow == workflow }
        cancelled.forEach { $0.continuation?.resume(throwing: CancellationError()) }
        dispatch()
        signalIdle()
    }

    func beginWorkflow(_ kind: WorkflowKind) throws -> UUID {
        guard !closed else { throw SessionFailure.notConnected }
        guard lease == nil, current == nil, queue.isEmpty else {
            throw SessionFailure.busy(lease?.kind ?? kind)
        }
        let id = UUID(); lease = (id, kind); return id
    }

    func endWorkflow(_ id: UUID) throws {
        guard lease?.id == id else { return }
        // Do not release ownership while a cancelled step is still retiring.
        guard current == nil, queue.isEmpty else { throw SessionFailure.busy(lease!.kind) }
        lease = nil
    }

    func waitUntilIdle() async throws {
        guard current != nil || !queue.isEmpty else { return }
        guard idleWaiters.count < 128 else { throw PolicyError.busy }
        let slot = PendingSlot<Void>()
        idleWaiters.append(slot)
        defer { idleWaiters.removeAll { $0 === slot } }
        try await slot.wait()
    }

    func close() {
        guard !closed else { return }
        closed = true; wake?.cancel(); wake = nil; lease = nil
        let pending = queue; queue = []
        pending.forEach { $0.continuation?.resume(throwing: SessionFailure.notConnected) }
        let continuation = current?.continuation
        current?.continuation = nil
        continuation?.resume(throwing: SessionFailure.notConnected)
        let waiters = idleWaiters; idleWaiters = []
        waiters.forEach { $0.finish(.failure(SessionFailure.notConnected)) }
        // The backend is closed by DeviceSession; an in-flight fragment remains
        // owned here until it completes/fails, with no later work appended.
    }
}
