import Foundation

/// Passive layouts from session 004; no commands or identity assertions.
public enum TourPro3Telemetry {
    public enum Component: Sendable, Equatable {
        case agent, partner, chargingCase, earbuds
    }

    public struct BatteryReport: Sendable, Equatable {
        public let component: Component
        public let percent: Int
        // Charging, dock state and agent-to-L/R mapping need separate evidence.
    }

    public struct FirmwareReport: Sendable, Equatable {
        public let component: Component
        public let version: String
    }

    public static func decodeBattery(_ frame: RaceFrame) -> BatteryReport? {
        guard frame.kind == .notification else { return nil }
        let bytes = [UInt8](frame.payload)
        switch frame.id {
        case 0x0CD6:
            guard bytes.count == 3, bytes[0] == 0, bytes[2] <= 100 else { return nil }
            let component: Component
            switch bytes[1] {
            case 0: component = .agent
            case 1: component = .partner
            default: return nil
            }
            return BatteryReport(component: component, percent: Int(bytes[2]))
        case 0x000B:
            guard bytes.count == 2, bytes[0] == 0, bytes[1] <= 100 else { return nil }
            return BatteryReport(component: .chargingCase, percent: Int(bytes[1]))
        default:
            return nil
        }
    }

    public static func decodeFirmware(_ frame: RaceFrame) -> FirmwareReport? {
        guard frame.kind == .notification else { return nil }
        let bytes = [UInt8](frame.payload)
        let component: Component
        let versionBytes: ArraySlice<UInt8>
        switch frame.id {
        case 0x1C07:
            // Captured [00, 00, stringLength, "v" + ASCII version]. Receiving
            // this event does not authorize sending the blocked 1Cxx command.
            guard bytes.count >= 9, bytes.count <= 15,
                  bytes[0] == 0, bytes[1] == 0,
                  Int(bytes[2]) == bytes.count - 3, bytes[3] == 0x76 else { return nil }
            component = .earbuds
            versionBytes = bytes.dropFirst(4)
        case 0x000F:
            guard bytes.count >= 6, bytes.count <= 12, bytes[0] == 0 else { return nil }
            component = .chargingCase
            versionBytes = bytes.dropFirst()
        default:
            return nil
        }
        guard let version = String(bytes: versionBytes, encoding: .ascii) else { return nil }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && UInt8($0) != nil
        }) else { return nil }
        return FirmwareReport(component: component, version: version)
    }
}
