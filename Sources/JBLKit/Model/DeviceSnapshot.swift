import Foundation

public enum SessionPhase: String, Sendable, Equatable {
    case idle, connecting, telemetryReady, ready, controlsUnavailable, released, sleeping
}

public enum DeviceValue: Sendable, Equatable {
    case mode(TourPro3Sound.ListeningMode)
    case bool(Bool)
    case integer(Int)
    case text(String)
}

public struct ConfirmedValue: Sendable, Equatable {
    public let value: DeviceValue
    public let observedAt: Date
    public internal(set) var isStale: Bool
    public init(value: DeviceValue, observedAt: Date, isStale: Bool = false) {
        self.value = value; self.observedAt = observedAt; self.isStale = isStale
    }
}

public enum IntentStatus: Sendable, Equatable { case pending, unconfirmed }
public struct DeviceIntent: Sendable, Equatable {
    public let id: UUID
    public let value: DeviceValue
    public internal(set) var status: IntentStatus
    public init(id: UUID = UUID(), value: DeviceValue, status: IntentStatus = .pending) {
        self.id = id; self.value = value; self.status = status
    }
}

public enum DeviceCommand: Sendable, Equatable {
    case listeningMode(TourPro3Sound.ListeningMode)
    /// Unmapped commands fail before an encoder or transport is consulted.
    case setting(feature: FeatureKey, value: DeviceValue)

    public var feature: FeatureKey {
        switch self { case .listeningMode: .listeningMode; case .setting(let feature, _): feature }
    }
    public var value: DeviceValue {
        switch self { case .listeningMode(let mode): .mode(mode); case .setting(_, let value): value }
    }
}

public enum DeviceAction: Sendable, Equatable { case findMyBuds, stopFindMyBuds }
public enum WorkflowKind: String, Sendable, Equatable { case findMyBuds, fitTest, caseTransfer }
public enum ChangeOutcome: Sendable, Equatable {
    case confirmed
    case superseded(by: UUID)
    case unconfirmed
    case declined(status: UInt8)
}
public enum ActionOutcome: Sendable, Equatable { case accepted, observed }
public enum SessionFailure: Error, Sendable, Equatable {
    case unsupported, notConnected, cancelled, indeterminate, failed, unconfirmed
    case busy(WorkflowKind), streamAlreadyAttached, staleGeneration, sleeping
}

/// Complete replacements are published. Confirmed state is never restored from
/// an old snapshot after a failed edit; only decoded device data can replace it.
public struct DeviceSnapshot: Sendable, Equatable {
    public internal(set) var selectedDevice: DeviceReference?
    public internal(set) var generation: UInt64 = 0
    public internal(set) var phase: SessionPhase = .idle
    public internal(set) var capabilities: [FeatureKey: FeatureAvailability] = ModelCatalog.tourPro3.features
    public internal(set) var confirmed: [FeatureKey: ConfirmedValue] = [:]
    public internal(set) var intents: [FeatureKey: DeviceIntent] = [:]
    // RACE agent/partner roles are not permanently mapped to left/right.
    public internal(set) var batteryAgent: BatteryReading = .unknown
    public internal(set) var batteryPartner: BatteryReading = .unknown
    public internal(set) var caseBattery: BatteryReading = .unknown
    public internal(set) var batteryReadingsStale = true
    public internal(set) var batteryAgentStale = true
    public internal(set) var batteryPartnerStale = true
    public internal(set) var caseBatteryStale = true
    public internal(set) var earbudFirmware: String?
    public internal(set) var caseFirmware: String?
    public internal(set) var workflow: WorkflowKind?
    public internal(set) var errors: [FeatureKey: SessionFailure] = [:]
    public internal(set) var isRefreshing = false
    /// Value construction grants no transport access and cannot change the
    /// actor's store. Also used by offline UI previews and accessibility tests.
    public init(selectedDevice: DeviceReference? = nil, generation: UInt64 = 0,
                phase: SessionPhase = .idle,
                capabilities: [FeatureKey: FeatureAvailability] = ModelCatalog.tourPro3.features,
                confirmed: [FeatureKey: ConfirmedValue] = [:], intents: [FeatureKey: DeviceIntent] = [:],
                batteryAgent: BatteryReading = .unknown, batteryPartner: BatteryReading = .unknown,
                caseBattery: BatteryReading = .unknown, batteryReadingsStale: Bool = true,
                batteryAgentStale: Bool = true, batteryPartnerStale: Bool = true,
                caseBatteryStale: Bool = true, earbudFirmware: String? = nil, caseFirmware: String? = nil,
                workflow: WorkflowKind? = nil, errors: [FeatureKey: SessionFailure] = [:],
                isRefreshing: Bool = false) {
        self.selectedDevice = selectedDevice; self.generation = generation; self.phase = phase
        self.capabilities = capabilities; self.confirmed = confirmed; self.intents = intents
        self.batteryAgent = batteryAgent; self.batteryPartner = batteryPartner; self.caseBattery = caseBattery
        self.batteryReadingsStale = batteryReadingsStale; self.batteryAgentStale = batteryAgentStale
        self.batteryPartnerStale = batteryPartnerStale; self.caseBatteryStale = caseBatteryStale
        self.earbudFirmware = earbudFirmware; self.caseFirmware = caseFirmware
        self.workflow = workflow; self.errors = errors; self.isRefreshing = isRefreshing
    }

    public func displayedValue(for feature: FeatureKey) -> DeviceValue? {
        intents[feature]?.value ?? confirmed[feature]?.value
    }
}
