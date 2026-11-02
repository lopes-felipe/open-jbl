import Foundation
import IOBluetooth
import JBLKit

public struct PairedDevice: Sendable, Identifiable, Equatable {
    public let reference: DeviceReference
    public let classicConnected: Bool
    /// Cached SDP only. Absence does not prove the device lacks the service.
    public let cachedControlChannel: Int?
    public var id: String { reference.id }
}

/// No inquiry, pairing, SDP query, connection open, audio route change or timer.
/// All IOBluetooth objects (including cached SDP objects) remain on the run loop.
public enum ClassicDeviceMonitor {
    public static func pairedDevices() async throws -> [PairedDevice] {
        let result = PendingSlot<[PairedDevice]>()
        IOBluetoothThread.shared.perform {
            let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
                .filter { device in
                    ModelCatalog.all.contains { $0.name == device.name } ||
                    device.getServiceRecord(for: RFCOMMLink.serviceUUID()) != nil
                }
                .compactMap { device -> PairedDevice? in
                    guard let address = device.addressString, device.isPaired() else { return nil }
                    var channel: BluetoothRFCOMMChannelID = 0
                    let service = device.getServiceRecord(for: RFCOMMLink.serviceUUID())
                    let found = service?.getRFCOMMChannelID(&channel) == kIOReturnSuccess &&
                        (1...30).contains(Int(channel))
                    return PairedDevice(reference: DeviceReference(address: address, name: device.name ?? "JBL device"),
                                        classicConnected: device.isConnected(),
                                        cachedControlChannel: found ? Int(channel) : nil)
                }
            result.finish(.success(devices))
        }
        return try await result.wait()
    }
}
