import Foundation

public enum OperationComponent: String, Sendable, CaseIterable {
    case earbuds, partner, chargingCase
}

public enum ComponentState: Sendable { case connected, inCase, notConnected, unknown }

public enum FirmwareApplicability: Sendable {
    case any
    case exact(Set<String>)
    /// Prefixes are literal, source-reviewed version prefixes (for example "6.0.").
    case prefixes(Set<String>)

    func allows(_ version: String?) -> Bool {
        switch self {
        case .any: true
        case .exact(let versions): version.map(versions.contains) ?? false
        case .prefixes(let prefixes): version.map { version in prefixes.contains { version.hasPrefix($0) } } ?? false
        }
    }
    var valid: Bool {
        switch self {
        case .any: true
        case .exact(let values), .prefixes(let values):
            !values.isEmpty && values.allSatisfy { !$0.isEmpty && $0.count <= 64 &&
                $0.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") } }
        }
    }
}

public struct OperationApplicability: Sendable {
    public let modelPIDs: Set<UInt16>?
    public let casePIDs: Set<UInt16>?
    public let component: OperationComponent
    public let firmware: FirmwareApplicability
    public let requiredCapabilities: Set<FeatureKey>

    init(modelPIDs: Set<UInt16>? = nil, casePIDs: Set<UInt16>? = nil,
         component: OperationComponent = .earbuds, firmware: FirmwareApplicability = .any,
         requiredCapabilities: Set<FeatureKey> = []) {
        self.modelPIDs = modelPIDs; self.casePIDs = casePIDs; self.component = component
        self.firmware = firmware; self.requiredCapabilities = requiredCapabilities
    }
}

public enum OperationPrecondition: Sendable {
    case noWorkflow
    case componentConnected(OperationComponent)
    case capability(FeatureKey)
}

/// Offsets refer to the logical RACE payload, never transport fragments.
public struct FieldRange: Sendable {
    public let name: String
    public let bytes: Range<Int>
    init(_ name: String, bytes: Range<Int>) { self.name = name; self.bytes = bytes }
    var valid: Bool { !name.isEmpty && bytes.lowerBound >= 0 && !bytes.isEmpty }
    func fits(_ payload: Data) -> Bool { valid && bytes.upperBound <= payload.count }
}

/// Filled only from a fresh dispatch-time device read by the owning session.
/// The policy rejects a compound write if preservation evidence is missing/stale.
public struct PreservedFieldValue: Sendable {
    public let bytes: Data
    public let observedAt: ContinuousClock.Instant
    public init(bytes: Data, observedAt: ContinuousClock.Instant = .now) {
        self.bytes = bytes; self.observedAt = observedAt
    }
}

public enum Correlation: Sendable {
    case none
    case payloadByte(identifier: UInt16, kind: RaceFrame.Kind, offset: Int, value: UInt8)

    static func inferred(from completion: CompletionRule) -> Correlation {
        switch completion {
        case .response: .none
        case .indication(let id, let kind, let role?, let offset),
             .responseThenIndication(_, let id, let kind, let role?, let offset):
            .payloadByte(identifier: id, kind: kind, offset: offset, value: role)
        default: .none
        }
    }

    func matches(_ completion: CompletionRule) -> Bool {
        switch self {
        case .none: return true
        case .payloadByte(let id, let kind, let offset, let value):
            guard offset >= 0, offset < 65_533 else { return false }
            switch completion {
            case .indication(let expectedID, let expectedKind, let role, let expectedOffset),
                 .responseThenIndication(_, let expectedID, let expectedKind, let role, let expectedOffset):
                return id == expectedID && kind == expectedKind && role == value && offset == expectedOffset
            default: return false
            }
        }
    }
}

/// The transport has a fixed 5 s fragment deadline. Longer logical operations
/// must declare a bounded total; a response cannot exceed that total.
public struct OperationDeadlines: Sendable {
    public let response: Duration
    public let total: Duration
    public var fragmentWrite: Duration { .seconds(5) }
    public var followUpReadback: Duration { .seconds(5) }
    init(response: Duration = .seconds(5), total: Duration = .seconds(10)) {
        self.response = response; self.total = total
    }
    var valid: Bool {
        response > .zero && response <= .seconds(30) &&
            total >= response && total >= fragmentWrite && total <= .seconds(120)
    }
}

public enum ExpectedEffect: Sendable {
    case disconnect, reconfiguration
    case delayedApplication(maximum: Duration)
}

public enum SensitiveKind: Sendable { case address, serial, name, personalization, opaque }
public struct SensitiveField: Sendable {
    public let kind: SensitiveKind
    /// nil means the complete payload. Export currently withholds every payload.
    public let bytes: Range<Int>?
    init(_ kind: SensitiveKind, bytes: Range<Int>? = nil) { self.kind = kind; self.bytes = bytes }
    func fits(_ payload: Data) -> Bool {
        guard let bytes else { return true }
        return bytes.lowerBound >= 0 && !bytes.isEmpty && bytes.upperBound <= payload.count
    }
}

/// A source-defined proof, never permission to send NV on its own. No NV spec
/// is enabled until its atomic write/ACK/reload engine and fixture proof exist.
public struct NVTransactionSpec: Sendable {
    public let fixture: String
    public let writeIdentifier: UInt16
    public let key: Data
    public let keyRange: Range<Int>
    public let values: Set<Data>
    public let valueRange: Range<Int>
    public let capturedPayloads: Set<Data>
    public let reloadPayload: Data
    public let reloadWindow: Duration
    public var reloadIdentifier: UInt16 { 0x0A09 }

    init(fixture: String, writeIdentifier: UInt16, key: Data, keyRange: Range<Int>,
         values: Set<Data>, valueRange: Range<Int>, capturedPayloads: Set<Data>, reloadPayload: Data,
         reloadWindow: Duration = .seconds(2)) {
        self.fixture = fixture; self.writeIdentifier = writeIdentifier; self.key = key
        self.keyRange = keyRange; self.values = values; self.valueRange = valueRange
        self.capturedPayloads = capturedPayloads
        self.reloadPayload = reloadPayload; self.reloadWindow = reloadWindow
    }
    var valid: Bool {
        guard !fixture.isEmpty && [0x0A01, 0x0A0D].contains(writeIdentifier) &&
            !key.isEmpty && keyRange.lowerBound >= 0 && keyRange.upperBound <= 65_533 &&
            keyRange.count == key.count && valueRange.lowerBound >= 0 &&
            valueRange.upperBound <= 65_533 && !valueRange.isEmpty &&
            !keyRange.overlaps(valueRange) && !values.isEmpty &&
            values.allSatisfy({ $0.count == valueRange.count }) &&
            reloadWindow > .zero && reloadWindow <= .seconds(2) &&
            reloadPayload.count <= 256 && !capturedPayloads.isEmpty else { return false }
        var capturedValues: Set<Data> = []
        for payload in capturedPayloads {
            guard payload.count <= 65_533, keyRange.upperBound <= payload.count,
                  valueRange.upperBound <= payload.count else { return false }
            let bytes = Array(payload)
            guard Data(bytes[keyRange]) == key else { return false }
            capturedValues.insert(Data(bytes[valueRange]))
        }
        return capturedValues == values
    }
    func matches(_ frame: RaceFrame) -> Bool {
        guard valid, frame.id == writeIdentifier, capturedPayloads.contains(frame.payload),
              keyRange.upperBound <= frame.payload.count,
              valueRange.upperBound <= frame.payload.count else { return false }
        let payload = Array(frame.payload)
        return Data(payload[keyRange]) == key && values.contains(Data(payload[valueRange]))
    }
}
