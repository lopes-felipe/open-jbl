import Foundation

public enum ProtocolStack: String, Sendable, Codable { case race, harmanAA, harmanP4 }
public enum SupportLevel: String, Sendable { case verified, experimental }
public enum FeatureAvailability: String, Sendable, CaseIterable {
    case supported, readOnly, temporarilyUnavailable, unsupported, unknown, indeterminate
}
public enum FeatureKey: String, Sendable, CaseIterable {
    case identity, battery, firmware, listeningMode, ambientLevel, equalizer, customEQ
    case spatial, headTracking, gestures, voicePrompts, autoOff, findMyBuds, hiRes
    case lowVolumeEQ, smartTalk, silentNow, autoPlayPause, personiFi, sources, caseSettings, caseTime
}
public struct ModelInfo: Sendable {
    public let name: String
    public let pids: Set<UInt16>
    public let casePID: UInt16
    public let stack: ProtocolStack
    public let support: SupportLevel
    public let enabledOperations: Set<String>
    public let features: [FeatureKey: FeatureAvailability]
}
public enum ModelCatalog {
    /// Target of verification, not a claim that any feature has passed hardware acceptance.
    /// Every enabled operation has a reviewed, sanitized capture fixture.
    public static let tourPro3 = ModelInfo(
        name: "JBL Tour Pro 3", pids: [0x20F2], casePID: 0x20FD,
        stack: .race, support: .verified,
        enabledOperations: ["battery-agent", "battery-partner", "case-firmware", "listening-mode", "earbud-firmware",
                            "test-ambient", "test-anc"],
        features: Dictionary(uniqueKeysWithValues: FeatureKey.allCases.map { ($0, .unknown) })
    )
    public static let all: [ModelInfo] = [tourPro3]
    public static func integrityErrors() -> [String] {
        OperationCatalog.production.integrityErrors() + all.flatMap { model in
            model.enabledOperations.compactMap { name in
                OperationCatalog.production[name] == nil ? "\(model.name): missing spec \(name)" : nil
            }
        }
    }
}

public enum BatteryReading: Sendable, Equatable {
    case level(percent: Int, charging: Bool, observedAt: Date)
    case inCase, notConnected, unknown
}

public struct DeviceReference: Sendable, Identifiable, Hashable, Codable {
    public let address: String
    public let name: String
    public var id: String { address }
    public init(address: String, name: String) { self.address = address; self.name = name }
}
