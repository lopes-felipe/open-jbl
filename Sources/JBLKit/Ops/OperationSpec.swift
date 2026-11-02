import Foundation

public enum ConfirmLevel: Sendable { case audible, disruptive }
public enum OpKind: Sendable { case read, write, action(ConfirmLevel), heartbeat }
public enum OpArgs: Sendable, Equatable {
    case none, bool(Bool), int(Int), choice(UInt8)
    case autoOff(enabled: Bool, minutes: Int)
}
public enum Evidence: Sendable {
    case captured(fixture: String, firmwareIndependent: Bool)
    case documented(source: String)
    case none
}
public enum CompletionRule: Sendable {
    case response(UInt16)
    case responseThenIndication(response: UInt16, indication: UInt16,
                                kind: RaceFrame.Kind = .indication, role: UInt8?, roleOffset: Int = 0)
    case indication(UInt16, kind: RaceFrame.Kind = .indication, role: UInt8?, roleOffset: Int = 0)
}
public enum ArgError: Error, Equatable { case invalid, outOfRange }
public enum PolicyError: Error, Equatable {
    case unknownOperation, modelMismatch, invalidArguments, missingCapture, missingEvidence
    case identityRequired, experimentalDisabled, confirmationRequired, unknownFirmware
    case blocked(UInt16), malformedMessage, nestedMessage, busy, connectionGuard, unsupported
    case invalidMetadata, firmwareMismatch, componentUnavailable, preconditionFailed, preservationRequired
}

/// Only reviewed source tables inside JBLKit can construct specs. Clients select a name.
/// A caller cannot smuggle an encoder or evidence assertion through the send API.
public struct OperationSpec: Sendable {
    public let name: String
    public let stack: ProtocolStack
    public let kind: OpKind
    public let evidence: Evidence
    public let completion: CompletionRule
    public let applicability: OperationApplicability
    public let correlation: Correlation
    public let preconditions: [OperationPrecondition]
    public let preservedFields: [FieldRange]
    public let deadlines: OperationDeadlines
    public let expectedEffects: [ExpectedEffect]
    public let sensitive: [SensitiveField]
    public let nvTransaction: NVTransactionSpec?
    public var responseDeadline: Duration { deadlines.response }
    let encode: @Sendable (OpArgs) throws -> RaceFrame
    let nestedOperation: String?
    let unwrap: (@Sendable (Data) throws -> Data)?

    init(name: String, stack: ProtocolStack = .race, kind: OpKind, evidence: Evidence,
         completion: CompletionRule, responseDeadline: Duration = .seconds(5),
         applicability: OperationApplicability = OperationApplicability(),
         correlation: Correlation? = nil, preconditions: [OperationPrecondition] = [],
         preservedFields: [FieldRange] = [], deadlines: OperationDeadlines? = nil,
         expectedEffects: [ExpectedEffect] = [], sensitive: [SensitiveField] = [],
         nvTransaction: NVTransactionSpec? = nil,
         nestedOperation: String? = nil, unwrap: (@Sendable (Data) throws -> Data)? = nil,
         encode: @escaping @Sendable (OpArgs) throws -> RaceFrame) {
        self.name = name; self.stack = stack; self.kind = kind; self.evidence = evidence
        self.completion = completion; self.applicability = applicability
        self.correlation = correlation ?? .inferred(from: completion)
        self.preconditions = preconditions; self.preservedFields = preservedFields
        self.deadlines = deadlines ?? OperationDeadlines(response: responseDeadline,
                                                        total: max(.seconds(10), responseDeadline))
        self.expectedEffects = expectedEffects; self.sensitive = sensitive; self.nvTransaction = nvTransaction
        self.nestedOperation = nestedOperation; self.unwrap = unwrap; self.encode = encode
    }

    var metadataValid: Bool {
        guard !name.isEmpty, deadlines.valid, applicability.firmware.valid,
              applicability.modelPIDs?.isEmpty != true, applicability.casePIDs?.isEmpty != true,
              correlation.matches(completion), preservedFields.allSatisfy(\.valid),
              Set(preservedFields.map(\.name)).count == preservedFields.count else { return false }
        for left in preservedFields.indices {
            for right in preservedFields.indices where left < right {
                if preservedFields[left].bytes.overlaps(preservedFields[right].bytes) { return false }
            }
        }
        for effect in expectedEffects {
            if case .delayedApplication(let maximum) = effect,
               maximum <= .zero || maximum > deadlines.total { return false }
        }
        if let nvTransaction {
            guard nvTransaction.valid, case .write = kind,
                  case .captured(let fixture, _) = evidence, fixture == nvTransaction.fixture else { return false }
        }
        return true
    }
}

public struct OperationCatalog: Sendable {
    private let specs: [String: OperationSpec]
    init(_ specs: [OperationSpec]) {
        precondition(Set(specs.map(\.name)).count == specs.count)
        self.specs = Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0) })
    }
    public static let production = OperationCatalog(TourPro3Reads.specs + TourPro3ModeTests.specs)
    public subscript(_ name: String) -> OperationSpec? { specs[name] }
    public var names: [String] { specs.keys.sorted() }
    public func integrityErrors() -> [String] {
        names.compactMap { name in
            guard let spec = specs[name], spec.metadataValid else { return "\(name): invalid operation metadata" }
            if let inner = spec.nestedOperation, specs[inner] == nil { return "\(name): missing nested operation" }
            if let frame = try? spec.encode(.none) {
                if !spec.preservedFields.allSatisfy({ $0.fits(frame.payload) }) ||
                    !spec.sensitive.allSatisfy({ $0.fits(frame.payload) }) {
                    return "\(name): field range outside payload"
                }
                if let nv = spec.nvTransaction, !nv.matches(frame) { return "\(name): NV proof does not match request" }
            }
            return nil
        }
    }
}

public struct OperationRequest: Sendable {
    public let name: String
    public let args: OpArgs
    public let confirmation: ConfirmationToken?
    public init(_ name: String, args: OpArgs = .none, confirmation: ConfirmationToken? = nil) {
        self.name = name; self.args = args; self.confirmation = confirmation
    }
}

public struct ConfirmationToken: Sendable {
    public let operation: String
    let expires: ContinuousClock.Instant
    public init(userConfirmed operation: String) {
        self.operation = operation
        expires = ContinuousClock.now.advanced(by: .seconds(30))
    }
}

public struct PolicyContext: Sendable {
    public var model: ModelInfo
    public var identityVerified: Bool
    public var firmwareKnown: Bool
    public var allowExperimentalChanges: Bool
    public var firmwareVersion: String?
    public var permittedComponents: Set<OperationComponent>
    public var capabilities: [FeatureKey: FeatureAvailability]
    public var componentStates: [OperationComponent: ComponentState]
    public var preservedFields: [String: PreservedFieldValue]
    public var workflowActive: Bool
    public init(model: ModelInfo = ModelCatalog.tourPro3, identityVerified: Bool = false,
                firmwareKnown: Bool = false, allowExperimentalChanges: Bool = false,
                firmwareVersion: String? = nil,
                permittedComponents: Set<OperationComponent> = Set(OperationComponent.allCases),
                capabilities: [FeatureKey: FeatureAvailability] = [:],
                componentStates: [OperationComponent: ComponentState] = [:],
                preservedFields: [String: PreservedFieldValue] = [:], workflowActive: Bool = false) {
        self.model = model; self.identityVerified = identityVerified; self.firmwareKnown = firmwareKnown
        self.allowExperimentalChanges = allowExperimentalChanges
        self.firmwareVersion = firmwareVersion; self.permittedComponents = permittedComponents
        self.capabilities = capabilities; self.componentStates = componentStates
        self.preservedFields = preservedFields; self.workflowActive = workflowActive
    }
}
