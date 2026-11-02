import Foundation

public enum ControlRestartTrigger: Sendable { case classicConnected, poweredOn, wake, interfaceOpened, retry }
public enum ControlAcquisitionPhase: Sendable, Equatable { case idle, connecting, waitingToRetry, connected, unavailable }

/// Value-only acquisition orchestration. A production factory must create a
/// GuardedSession using the same revocable AcquisitionPermit as its transport.
/// The factory is never called while a required connection guard is false.
public actor DiscoveryCoordinator {
    public typealias Factory = @Sendable (DeviceReference, AcquisitionPermit) async throws -> any SessionConnection
    private let session: DeviceSession
    private let factory: Factory
    private let clock: SessionClock
    private var context = AcquisitionContext(selectedAndPaired: false, classicConnected: false, controlNeeded: false)
    private var epoch: UInt64 = 0
    private var revision: UInt64 = 0
    private var task: Task<Void, Never>?
    private var permit: AcquisitionPermit?
    public private(set) var phase: ControlAcquisitionPhase = .idle

    public init(session: DeviceSession, clock: SessionClock = .live, factory: @escaping Factory) {
        self.session = session; self.clock = clock; self.factory = factory
    }
    deinit {
        task?.cancel()
        permit?.update(AcquisitionContext(selectedAndPaired: false, classicConnected: false, controlNeeded: false))
        let session = session
        Task { await session.releaseControls() }
    }

    public func update(_ context: AcquisitionContext, restart: ControlRestartTrigger? = nil) async {
        revision &+= 1
        let requestRevision = revision
        self.context = context
        // Synchronous revocation reaches transport guards even while its open
        // or write callback is suspended on another thread.
        permit?.update(context)
        guard context.allowsAcquisition else {
            epoch &+= 1; task?.cancel(); task = nil; phase = .idle
            if !context.awake { await session.setAwake(false) }
            else { await session.releaseControls() }
            return
        }
        guard let restart else { return }
        let sessionPhase = await session.currentSnapshot().phase
        guard requestRevision == revision, self.context.allowsAcquisition else { return }
        if sessionPhase == .ready || sessionPhase == .telemetryReady { phase = .connected; return }
        permit?.update(AcquisitionContext(selectedAndPaired: false, classicConnected: false, controlNeeded: false))
        epoch &+= 1
        let current = epoch
        task?.cancel()
        if case .retry = restart { await session.retry() }
        await session.setAwake(true)
        guard current == epoch, requestRevision == revision, self.context.allowsAcquisition else { return }
        // A new trigger resets the retry budget. It does not preempt an already
        // healthy link or a workflow merely because a panel was opened.
        task = Task { await self.acquire(epoch: current, wakeDelay: restart == .wake) }
    }

    private func acquire(epoch expected: UInt64, wakeDelay: Bool) async {
        if wakeDelay {
            do { try await clock.sleep(.seconds(2)) } catch { return }
        }
        let delays: [Duration] = [.zero, .seconds(1), .seconds(2), .seconds(4)]
        for delay in delays {
            guard expected == epoch, context.allowsAcquisition, !Task.isCancelled else { return }
            if delay > .zero {
                phase = .waitingToRetry
                do { try await clock.sleep(delay) } catch { return }
            }
            guard expected == epoch, context.allowsAcquisition, !Task.isCancelled,
                  let selected = await session.currentSnapshot().selectedDevice else { return }
            phase = .connecting
            let permit = AcquisitionPermit(context)
            self.permit = permit
            do {
                let candidate = try await factory(selected, permit)
                guard expected == epoch, context.allowsAcquisition, !Task.isCancelled else {
                    await candidate.stop(); return
                }
                try await session.acquire(using: candidate)
                guard expected == epoch, context.allowsAcquisition, !Task.isCancelled else {
                    await candidate.stop(); return
                }
                phase = .connected
                return
            } catch {
                permit.update(AcquisitionContext(selectedAndPaired: false, classicConnected: false, controlNeeded: false))
                guard expected == epoch, context.allowsAcquisition, !Task.isCancelled else { return }
            }
        }
        if expected == epoch { phase = .unavailable; task = nil }
    }
}
