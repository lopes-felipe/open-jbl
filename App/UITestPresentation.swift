import Foundation
import JBLKit

/// Explicit launch-only synthetic values. AppModel exits before attaching the
/// real session or requesting Bluetooth whenever this argument is present.
enum UITestPresentation: String {
    case pending, confirmed, stale, busy, indeterminate
    static var requested: UITestPresentation? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--ui-test-state") else { return nil }
        guard args.indices.contains(index + 1) else { return .confirmed }
        return UITestPresentation(rawValue: args[index + 1]) ?? .confirmed
    }
    var snapshot: DeviceSnapshot {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var capabilities = ModelCatalog.tourPro3.features
        capabilities[.listeningMode] = self == .indeterminate ? .indeterminate : .supported
        let intent: [FeatureKey: DeviceIntent] = self == .pending ?
            [.listeningMode: DeviceIntent(value: .mode(.ambient))] : [:]
        return DeviceSnapshot(
            selectedDevice: DeviceReference(address: "11-22-33-44-55-66", name: "Synthetic Tour Pro 3"),
            phase: self == .stale ? .released : .ready,
            capabilities: capabilities,
            confirmed: [.listeningMode: ConfirmedValue(value: .mode(.anc), observedAt: date, isStale: self == .stale)],
            intents: intent, batteryAgent: .level(percent: 51, charging: false, observedAt: date),
            batteryPartner: .level(percent: 52, charging: false, observedAt: date),
            caseBattery: .level(percent: 53, charging: false, observedAt: date),
            batteryReadingsStale: self == .stale,
            batteryAgentStale: self == .stale, batteryPartnerStale: self == .stale,
            caseBatteryStale: self == .stale, earbudFirmware: "synthetic", caseFirmware: "synthetic",
            workflow: self == .busy ? .findMyBuds : nil
        )
    }
}
