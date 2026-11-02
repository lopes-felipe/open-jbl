import Foundation
import CoreBluetooth
import JBLKit

public enum BluetoothStatus: String, Sendable {
    case notDetermined, unauthorized, poweredOff, poweredOn, unavailable
}

/// CoreBluetooth is used only to request permission and report adapter state at M1.
/// It never scans, retrieves, pairs or connects to a peripheral.
public final class BluetoothPermission: Sendable {
    public let updates: AsyncStream<BluetoothStatus>
    private let statusContinuation: AsyncStream<BluetoothStatus>.Continuation
    private static let queue = DispatchQueue(label: "io.github.lopesfelipe.OpenJBL.le")
    // Registry access and all CoreBluetooth releases are confined to queue.
    private nonisolated(unsafe) static var workers: [UUID: Worker] = [:]
    private let workerID = UUID()
    public init() {
        let (stream, continuation) = AsyncStream<BluetoothStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = stream
        statusContinuation = continuation
    }

    deinit {
        let id = workerID
        Self.queue.async { Self.workers.removeValue(forKey: id)?.close() }
    }

    public func requestStatus() async throws -> BluetoothStatus {
        let slot = PendingSlot<BluetoothStatus>()
        Self.queue.async {
            if Self.workers[self.workerID] == nil {
                Self.workers[self.workerID] = Worker(queue: Self.queue, updates: self.statusContinuation)
            }
            Self.workers[self.workerID]?.status(slot)
        }
        return try await withDeadline(.seconds(10)) { try await slot.wait() }
    }

    private final class Worker: NSObject, CBCentralManagerDelegate {
        private var manager: CBCentralManager!
        private var pending: PendingSlot<BluetoothStatus>?
        private let updates: AsyncStream<BluetoothStatus>.Continuation
        init(queue: DispatchQueue, updates: AsyncStream<BluetoothStatus>.Continuation) {
            self.updates = updates
            super.init()
            manager = CBCentralManager(delegate: self, queue: queue,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        func status(_ slot: PendingSlot<BluetoothStatus>) {
            if manager.state == .unknown || manager.state == .resetting {
                pending?.finish(.failure(LinkError.unavailable("Bluetooth status request superseded")))
                pending = slot
            } else { slot.finish(.success(value)) }
        }
        private var value: BluetoothStatus {
            if CBCentralManager.authorization == .denied || CBCentralManager.authorization == .restricted {
                return .unauthorized
            }
            switch manager.state {
            case .poweredOn: return .poweredOn
            case .poweredOff: return .poweredOff
            case .unauthorized: return .unauthorized
            default: return .unavailable
            }
        }
        func centralManagerDidUpdateState(_ central: CBCentralManager) {
            guard central.state != .unknown, central.state != .resetting else { return }
            updates.yield(value)
            pending?.finish(.success(value))
            pending = nil
        }
        func close() {
            updates.finish()
            pending?.finish(.failure(LinkError.disconnected))
            pending = nil
            manager.delegate = nil
            manager = nil
        }
    }
}
