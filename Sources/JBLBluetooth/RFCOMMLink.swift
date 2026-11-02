import Foundation
import IOBluetooth
import JBLKit

/// Single-use facade. Workers are retained/released only on IOBluetoothThread;
/// mtu is locked. No IOBluetooth object or delegate leaves that thread.
public final class RFCOMMLink: Link, @unchecked Sendable {
    public let generation: UInt64
    public let events: OrderedMailbox
    private let selected: DeviceReference
    private let permit: AcquisitionPermit
    private let lock = NSLock()
    private var mtu = 0
    private var binding: DeviceReference?
    public var boundDevice: DeviceReference? { lock.withLock { binding } }
    private let workerID = UUID()
    // This registry is touched only inside IOBluetoothThread.perform blocks.
    // Keeping it off the facade also confines final ARC release on deinit.
    private nonisolated(unsafe) static var workers: [UUID: Worker] = [:]
    private var used = false

    public init(selected: DeviceReference, generation: UInt64, permit: AcquisitionPermit) {
        self.selected = selected; self.generation = generation; self.permit = permit
        events = OrderedMailbox(generation: generation)
    }

    deinit {
        let id = workerID
        IOBluetoothThread.shared.perform { Self.workers.removeValue(forKey: id)?.close(nil) }
    }

    static func serviceUUID() -> IOBluetoothSDPUUID {
        IOBluetoothSDPUUID(data: Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
    }

    public func maximumWriteLength(_ endpoint: LinkEndpoint) -> Int {
        endpoint == .control ? lock.withLock { mtu } : 0
    }
    private func setMTU(_ value: Int) { lock.withLock { mtu = value } }
    private func setBinding(_ value: DeviceReference?) { lock.withLock { binding = value } }

    public func open() async throws {
        let slot = PendingSlot<Void>()
        IOBluetoothThread.shared.perform { [self] in
            guard !self.used else { slot.finish(.failure(LinkError.disconnected)); return }
            self.used = true
            let worker = Worker(selected: self.selected, permit: self.permit, events: self.events,
                                open: slot, updateMTU: { [weak self] in self?.setMTU($0) },
                                updateBinding: { [weak self] in self?.setBinding($0) })
            Self.workers[self.workerID] = worker
            worker.begin()
        }
        do {
            // Separate SDP (15s) and RFCOMM open (10s) timers run on the worker.
            try await withTaskCancellationHandler {
                try await slot.wait()
            } onCancel: { self.scheduleClose() }
        } catch { await close(); throw error }
    }

    public func write(_ fragment: Data, to endpoint: LinkEndpoint) async throws {
        guard endpoint == .control else { throw LinkError.unavailable("No raw RFCOMM endpoint") }
        let slot = PendingSlot<Void>()
        IOBluetoothThread.shared.perform {
            guard let worker = Self.workers[self.workerID] else { slot.finish(.failure(LinkError.disconnected)); return }
            worker.write(fragment, slot: slot)
        }
        do {
            try await withTaskCancellationHandler {
                try await slot.wait()
            } onCancel: { self.scheduleClose() }
        } catch { await close(); throw error }
    }

    private func scheduleClose() {
        setBinding(nil)
        IOBluetoothThread.shared.perform { Self.workers[self.workerID]?.close(.cancelled) }
    }
    public func close() async {
        setBinding(nil)
        let slot = PendingSlot<Void>()
        IOBluetoothThread.shared.perform {
            self.used = true
            Self.workers.removeValue(forKey: self.workerID)?.close(nil)
            self.setMTU(0)
            self.events.enqueue(.closed(nil))
            slot.finish(.success(()))
        }
        _ = try? await slot.wait()
    }

    private final class Worker: NSObject, IOBluetoothRFCOMMChannelDelegate {
        private let selected: DeviceReference
        private let permit: AcquisitionPermit
        private let events: OrderedMailbox
        private let updateMTU: @Sendable (Int) -> Void
        private let updateBinding: @Sendable (DeviceReference?) -> Void
        private let openSlot: PendingSlot<Void>
        private var device: IOBluetoothDevice?
        private var channel: IOBluetoothRFCOMMChannel?
        private var timer: Timer?
        private var disconnect: IOBluetoothUserNotification?
        private var closed = false
        private var opening = false
        private var channelRequested = false
        private var writeSlot: PendingSlot<Void>?
        private var buffer: UnsafeMutableRawPointer?
        private var bufferCount = 0
        private var submitted = false
        private var writeID: UInt64 = 0

        init(selected: DeviceReference, permit: AcquisitionPermit, events: OrderedMailbox,
             open: PendingSlot<Void>, updateMTU: @escaping @Sendable (Int) -> Void,
             updateBinding: @escaping @Sendable (DeviceReference?) -> Void) {
            self.selected = selected; self.permit = permit; self.events = events
            self.openSlot = open; self.updateMTU = updateMTU
            self.updateBinding = updateBinding
        }

        private var allowed: Bool {
            !closed && permit.allowsAcquisition &&
                device?.isConnected() == true && device?.isPaired() == true &&
                device?.addressString == selected.address &&
                selected.name == ModelCatalog.tourPro3.name &&
                device?.name == selected.name
        }

        func begin() {
            guard permit.allowsAcquisition,
                  let found = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?
                    .first(where: { $0.addressString == selected.address }) else {
                close(.unavailable("Select an already-paired device")); return
            }
            device = found
            guard allowed else { close(.disconnected); return }
            disconnect = found.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
            if found.getServiceRecord(for: RFCOMMLink.serviceUUID()) != nil { openChannel(); return }
            // Guard immediately before SDP. The OS call can still race an ACL loss.
            guard allowed else { close(.disconnected); return }
            deadline(15)
            let result = found.performSDPQuery(self, uuids: [RFCOMMLink.serviceUUID()])
            if result != kIOReturnSuccess { close(.io(result)) }
        }

        @objc func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
            guard !closed else { return }
            guard status == kIOReturnSuccess else { close(.io(status)); return }
            openChannel()
        }

        private func openChannel() {
            guard !channelRequested else { return }
            guard allowed, let device,
                  let record = device.getServiceRecord(for: RFCOMMLink.serviceUUID()) else {
                close(.unavailable("Airoha service unavailable on the existing Classic connection")); return
            }
            var id: BluetoothRFCOMMChannelID = 0
            guard record.getRFCOMMChannelID(&id) == kIOReturnSuccess, (1...30).contains(Int(id)) else {
                close(.unavailable("SDP has no RFCOMM channel")); return
            }
            guard allowed else { close(.disconnected); return }
            channelRequested = true
            deadline(10)
            opening = true
            let result = device.openRFCOMMChannelAsync(&channel, withChannelID: id, delegate: self)
            if result != kIOReturnSuccess { close(.io(result)) }
        }

        func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel, status error: IOReturn) {
            if !closed, !opening, channel === rfcommChannel { return }
            guard allowed, error == kIOReturnSuccess else {
                rfcommChannel.close()
                close(error == kIOReturnSuccess ? .disconnected : .io(error))
                return
            }
            channel = rfcommChannel
            opening = false; timer?.invalidate(); timer = nil
            updateMTU(Int(rfcommChannel.getMTU()))
            updateBinding(selected)
            guard events.enqueue(.opened) else { close(.overflow); return }
            openSlot.finish(.success(()))
        }

        func write(_ data: Data, slot: PendingSlot<Void>) {
            guard allowed, !opening, let channel else { slot.finish(.failure(LinkError.disconnected)); return }
            guard writeSlot == nil else { slot.finish(.failure(PolicyError.busy)); return }
            guard !data.isEmpty, data.count <= Int(channel.getMTU()) else {
                slot.finish(.failure(LinkError.messageTooLarge)); return
            }
            writeSlot = slot; writeID &+= 1
            bufferCount = data.count
            buffer = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 1)
            data.withUnsafeBytes { bytes in buffer!.copyMemory(from: bytes.baseAddress!, byteCount: data.count) }
            deadline(5)
            submitIfReady()
        }

        private func submitIfReady() {
            guard !submitted, let channel, let buffer, writeSlot != nil else { return }
            guard allowed else { close(.disconnected); return }
            guard !channel.isTransmissionPaused() else { return }
            submitted = true
            let status = channel.writeAsync(buffer, length: UInt16(bufferCount), refcon: nil)
            if status != kIOReturnSuccess { close(.io(status)) }
        }

        func rfcommChannelFlowControlChanged(_ rfcommChannel: IOBluetoothRFCOMMChannel) { submitIfReady() }
        func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel,
                                        refcon: UnsafeMutableRawPointer?, status error: IOReturn) {
            guard !closed, submitted else { return }
            guard error == kIOReturnSuccess else { close(.io(error)); return }
            timer?.invalidate(); timer = nil
            buffer?.deallocate(); buffer = nil
            submitted = false
            let slot = writeSlot; writeSlot = nil
            guard events.enqueue(.writeCompleted(writeID)) else { close(.overflow); slot?.finish(.failure(LinkError.overflow)); return }
            slot?.finish(.success(()))
        }

        func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel,
                               data dataPointer: UnsafeMutableRawPointer, length dataLength: Int) {
            guard !closed else { return }
            // Copy synchronously on callback ingress; no per-callback Task.
            guard events.enqueue(.data(.control, Data(bytes: dataPointer, count: dataLength))) else {
                close(.overflow); return
            }
        }
        func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel) { close(.disconnected) }
        @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
            close(.disconnected)
        }

        private func deadline(_ seconds: TimeInterval) {
            timer?.invalidate()
            timer = Timer.scheduledTimer(timeInterval: seconds, target: self,
                                         selector: #selector(timedOut), userInfo: nil, repeats: false)
        }
        @objc private func timedOut() { close(.timedOut) }

        func close(_ error: LinkError?) {
            guard !closed else { return }
            closed = true
            updateBinding(nil)
            timer?.invalidate(); timer = nil
            disconnect?.unregister(); disconnect = nil
            channel?.close()
            channel?.setDelegate(nil)
            channel = nil; device = nil
            buffer?.deallocate(); buffer = nil
            updateMTU(0)
            openSlot.finish(.failure(error ?? .disconnected))
            writeSlot?.finish(.failure(error ?? .disconnected)); writeSlot = nil
            events.enqueue(.closed(error))
        }
    }
}
