import Foundation

/// A callback may finish before installation, after cancellation, or more than once.
/// The lock protects the result and continuation; no foreign object crosses it.
public final class PendingSlot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?
    private var installed = false

    public init() {}

    public func wait() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if installed {
                    lock.unlock()
                    continuation.resume(throwing: LinkError.multipleConsumers)
                    return
                }
                installed = true
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    @discardableResult
    public func finish(_ result: Result<Value, any Error>) -> Bool {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return false }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}
