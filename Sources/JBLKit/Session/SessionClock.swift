import Foundation

/// Injected monotonic time and sleeps make debounce/idle policy deterministic.
/// Wall time is used only for the freshness timestamp shown to the user.
public struct SessionClock: Sendable {
    public let now: @Sendable () -> Duration
    public let date: @Sendable () -> Date
    public let sleep: @Sendable (Duration) async throws -> Void
    public init(now: @escaping @Sendable () -> Duration, date: @escaping @Sendable () -> Date,
                sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now; self.date = date; self.sleep = sleep
    }
    public static var live: SessionClock {
        let origin = ContinuousClock.now
        return SessionClock(now: { origin.duration(to: .now) }, date: { Date() },
                            sleep: { try await Task.sleep(for: $0) })
    }
}
