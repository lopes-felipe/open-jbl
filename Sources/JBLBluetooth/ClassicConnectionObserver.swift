import Foundation
import IOBluetooth
import JBLKit

public enum ClassicObservationError: Error, Sendable { case registrationFailed, overflow }

public struct ClassicConnectionEvent: Sendable {
    public let sequence: UInt64
    /// Nil means the selected reference is no longer paired.
    public let device: PairedDevice?
}

/// Passive notifications only. Registry, device, notifications and final ARC
/// release all stay on IOBluetoothThread; only copied values cross threads.
public final class ClassicConnectionObserver: Sendable {
    public let events: AsyncThrowingStream<ClassicConnectionEvent, Error>
    private let workerID: UUID
    private let startup: PendingSlot<Void>
    private nonisolated(unsafe) static var workers: [UUID: Worker] = [:]

    public init(selected: DeviceReference) {
        let id = UUID()
        workerID = id
        let startup = PendingSlot<Void>()
        self.startup = startup
        let (stream, continuation) = AsyncThrowingStream<ClassicConnectionEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(128))
        events = stream
        continuation.onTermination = { _ in
            IOBluetoothThread.shared.perform { Self.workers.removeValue(forKey: id)?.close() }
        }
        IOBluetoothThread.shared.perform {
            let worker = Worker(selected: selected, continuation: continuation)
            Self.workers[id] = worker
            worker.start()
            if worker.closed { startup.finish(.failure(ClassicObservationError.registrationFailed)) }
            else { startup.finish(.success(())) }
        }
    }

    deinit {
        let id = workerID
        IOBluetoothThread.shared.perform { Self.workers.removeValue(forKey: id)?.close() }
    }

    public func ready() async throws {
        let startup = startup
        try await withDeadline(.seconds(5)) { try await startup.wait() }
    }

    public func stop() async {
        let id = workerID
        let slot = PendingSlot<Void>()
        IOBluetoothThread.shared.perform {
            Self.workers.removeValue(forKey: id)?.close()
            slot.finish(.success(()))
        }
        _ = try? await slot.wait()
    }

    private final class Worker: NSObject {
        let selected: DeviceReference
        let continuation: AsyncThrowingStream<ClassicConnectionEvent, Error>.Continuation
        var connect: IOBluetoothUserNotification?
        var disconnect: IOBluetoothUserNotification?
        var device: IOBluetoothDevice?
        var sequence: UInt64 = 0
        var closed = false

        init(selected: DeviceReference,
             continuation: AsyncThrowingStream<ClassicConnectionEvent, Error>.Continuation) {
            self.selected = selected
            self.continuation = continuation
        }
        func start() {
            connect = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
            guard connect != nil else { close(ClassicObservationError.registrationFailed); return }
            // Paired-device lookup and cached SDP inspect no radio connection.
            device = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).first {
                $0.addressString?.caseInsensitiveCompare(selected.address) == .orderedSame && $0.isPaired()
            }
            if let device, device.isConnected() { armDisconnect(device) }
            publish()
        }
        @objc func connected(_ notification: IOBluetoothUserNotification, device incoming: IOBluetoothDevice) {
            guard !closed, incoming.addressString?.caseInsensitiveCompare(selected.address) == .orderedSame,
                  incoming.isPaired() else { return }
            device = incoming
            armDisconnect(incoming)
            publish()
        }
        @objc func disconnected(_ notification: IOBluetoothUserNotification, device incoming: IOBluetoothDevice) {
            guard !closed, incoming.addressString?.caseInsensitiveCompare(selected.address) == .orderedSame else { return }
            disconnect?.unregister()
            disconnect = nil
            device = incoming
            publish(forceDisconnected: true)
        }
        func armDisconnect(_ device: IOBluetoothDevice) {
            disconnect?.unregister()
            disconnect = device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
            if disconnect == nil { close(ClassicObservationError.registrationFailed) }
        }
        func publish(forceDisconnected: Bool = false) {
            guard !closed else { return }
            sequence &+= 1
            var value: PairedDevice?
            if let device, device.isPaired(), let address = device.addressString {
                var channel: BluetoothRFCOMMChannelID = 0
                let service = device.getServiceRecord(for: RFCOMMLink.serviceUUID())
                let found = service?.getRFCOMMChannelID(&channel) == kIOReturnSuccess && (1...30).contains(Int(channel))
                value = PairedDevice(reference: DeviceReference(address: address, name: device.name ?? selected.name),
                                     classicConnected: !forceDisconnected && device.isConnected(),
                                     cachedControlChannel: found ? Int(channel) : nil)
            }
            switch continuation.yield(ClassicConnectionEvent(sequence: sequence, device: value)) {
            case .enqueued: break
            case .dropped: close(ClassicObservationError.overflow)
            case .terminated: close()
            @unknown default: close(ClassicObservationError.overflow)
            }
        }
        func close(_ error: (any Error)? = nil) {
            guard !closed else { return }
            closed = true
            connect?.unregister(); connect = nil
            disconnect?.unregister(); disconnect = nil
            device = nil
            if let error { continuation.finish(throwing: error) }
            else { continuation.finish() }
        }
    }
}
