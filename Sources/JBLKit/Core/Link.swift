import Foundation

public enum LinkEndpoint: Sendable, Hashable { case control, raw }
public enum LinkError: Error, Sendable, Equatable {
    case disconnected, cancelled, overflow, multipleConsumers, messageTooLarge, timedOut
    case unavailable(String), io(Int32), poisoned
}
public enum LinkEvent: Sendable, Equatable {
    case opened
    case data(LinkEndpoint, Data)
    case writeCompleted(UInt64)
    case closed(LinkError?)

    var byteCount: Int {
        if case .data(_, let data) = self { return data.count }
        return 0
    }
    var isTerminal: Bool { if case .closed = self { return true }; return false }
}

public struct SequencedEvent: Sendable, Equatable {
    public let generation: UInt64
    public let sequence: UInt64
    public let event: LinkEvent
}

public protocol Link: Sendable {
    var generation: UInt64 { get }
    var events: OrderedMailbox { get }
    /// Value copied from the transport only after opening the selected paired
    /// channel; cleared synchronously when the transport closes.
    var boundDevice: DeviceReference? { get }
    func maximumWriteLength(_ endpoint: LinkEndpoint) -> Int
    func open() async throws
    func write(_ fragment: Data, to endpoint: LinkEndpoint) async throws
    func close() async
}

public extension Link {
    var boundDevice: DeviceReference? { nil }
}

/// Synchronous producer ingress. One waiter; terminal delivery has a reserved slot.
/// Synchronization covers all mutable storage, including sequence assignment.
public final class OrderedMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private let generation: UInt64
    private let maxBytes: Int
    private let maxEvents: Int
    private var queue: [SequencedEvent] = []
    private var bytes = 0
    private var sequence: UInt64 = 0
    private var terminal = false
    private var waiter: PendingSlot<SequencedEvent?>?

    /// A finite delivery barrier for the state consumer. Reading this counter
    /// does not consume events or change callback order.
    public var lastEnqueuedSequence: UInt64 { lock.withLock { sequence } }

    public init(generation: UInt64, maxBytes: Int = 1_048_576, maxEvents: Int = 1_024) {
        precondition(maxBytes > 0 && maxEvents > 0)
        self.generation = generation
        self.maxBytes = maxBytes
        self.maxEvents = maxEvents
    }

    /// False means overflow or an already closed stream: the producer must close its link.
    @discardableResult
    public func enqueue(_ event: LinkEvent) -> Bool {
        lock.lock()
        guard !terminal else { lock.unlock(); return false }
        let overflow = !event.isTerminal && (queue.count >= maxEvents || bytes + event.byteCount > maxBytes)
        let actual: LinkEvent = overflow ? .closed(.overflow) : event
        terminal = actual.isTerminal
        sequence &+= 1
        let item = SequencedEvent(generation: generation, sequence: sequence, event: actual)
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.finish(.success(item))
        } else {
            queue.append(item)
            bytes += actual.byteCount
            lock.unlock()
        }
        return !overflow
    }

    public func next() async throws -> SequencedEvent? {
        let slot = PendingSlot<SequencedEvent?>()
        try install(slot)
        return try await withTaskCancellationHandler {
            try await slot.wait()
        } onCancel: {
            self.cancel(slot)
        }
    }

    private func install(_ slot: PendingSlot<SequencedEvent?>) throws {
        lock.lock()
        guard waiter == nil else { lock.unlock(); throw LinkError.multipleConsumers }
        if !queue.isEmpty {
            let item = queue.removeFirst()
            bytes -= item.event.byteCount
            lock.unlock()
            slot.finish(.success(item))
        } else if terminal {
            lock.unlock()
            slot.finish(.success(nil))
        } else {
            waiter = slot
            lock.unlock()
        }
    }

    private func cancel(_ slot: PendingSlot<SequencedEvent?>) {
        lock.lock()
        if waiter === slot { waiter = nil }
        lock.unlock()
        slot.finish(.failure(CancellationError()))
    }
}

public func withDeadline<T: Sendable>(
    _ duration: Duration, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw LinkError.timedOut
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
