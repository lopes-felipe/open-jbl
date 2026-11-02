import Foundation

public enum SendPolicy {
    public static func validate(_ request: OperationRequest, in catalog: OperationCatalog,
                                context: PolicyContext) throws -> (OperationSpec, Data) {
        guard let spec = catalog[request.name],
              context.model.enabledOperations.contains(spec.name) else { throw PolicyError.unknownOperation }
        guard spec.stack == context.model.stack, spec.stack == .race else { throw PolicyError.modelMismatch }
        let frame: RaceFrame
        do { frame = try spec.encode(request.args) } catch { throw PolicyError.invalidArguments }
        try evidence(spec, context: context)
        switch spec.kind {
        case .read, .heartbeat: break
        case .write, .action:
            guard context.identityVerified else { throw PolicyError.identityRequired }
            if context.model.support == .experimental && !context.allowExperimentalChanges {
                throw PolicyError.experimentalDisabled
            }
        }
        if case .action = spec.kind {
            guard let token = request.confirmation, token.operation == spec.name,
                  token.expires >= ContinuousClock.now else { throw PolicyError.confirmationRequired }
        }
        if !context.firmwareKnown {
            guard case .read = spec.kind,
                  case .captured(_, firmwareIndependent: true) = spec.evidence else {
                throw PolicyError.unknownFirmware
            }
        }
        let bytes = try frame.encoded()
        let exact = try RaceFrame.exact(bytes)
        try checkFrame(exact, spec: spec, args: request.args, catalog: catalog, context: context)
        try metadata(spec, frame: exact, context: context)
        return (spec, bytes)
    }

    private static func evidence(_ spec: OperationSpec, context: PolicyContext) throws {
        switch spec.evidence {
        case .captured(let fixture, _):
            guard !fixture.isEmpty else { throw PolicyError.missingCapture }
        case .documented(let source):
            guard context.model.support == .experimental else { throw PolicyError.missingCapture }
            guard !source.isEmpty else { throw PolicyError.missingEvidence }
        case .none: throw PolicyError.missingEvidence
        }
    }

    private static func checkFrame(_ frame: RaceFrame, spec: OperationSpec, args: OpArgs,
                                   catalog: OperationCatalog, context: PolicyContext) throws {
        guard frame.kind == .command else { throw PolicyError.malformedMessage }
        // User-approved exception to plan §3.4: one direct, captured version read.
        // The ID stays on the blocklist, including for every wrapped operation.
        guard !Blocklists.race(frame.id) ||
                approvedFirmwareRead(frame, spec: spec, args: args, context: context) else {
            throw PolicyError.blocked(frame.id)
        }
        if [0x0D01, 0x0093].contains(frame.id) {
            guard let name = spec.nestedOperation, let inner = catalog[name],
                  context.model.enabledOperations.contains(name), inner.stack == spec.stack,
                  let unwrap = spec.unwrap else { throw PolicyError.nestedMessage }
            let nested = try RaceFrame.exact(unwrap(frame.payload))
            guard ![0x0D01, 0x0093].contains(nested.id) else { throw PolicyError.nestedMessage }
            guard nested.kind == .command else { throw PolicyError.malformedMessage }
            guard !Blocklists.race(nested.id) else { throw PolicyError.blocked(nested.id) }
            guard try nested.encoded() == inner.encode(args).encoded() else { throw PolicyError.nestedMessage }
            try evidence(inner, context: context)
            if !context.firmwareKnown {
                guard case .captured(_, firmwareIndependent: true) = inner.evidence else {
                    throw PolicyError.unknownFirmware
                }
            }
            // The outer spec may not downgrade an inner write to a read.
            switch (spec.kind, inner.kind) {
            case (.read, .read), (.write, .read), (.write, .write): break
            default: throw PolicyError.nestedMessage
            }
            try metadata(inner, frame: nested, context: context)
        }
    }

    /// This runs at actual dispatch, including for nested requests. Metadata
    /// cannot waive evidence, identity, firmware or blocklist checks above.
    private static func metadata(_ spec: OperationSpec, frame: RaceFrame, context: PolicyContext) throws {
        guard spec.metadataValid,
              spec.preservedFields.allSatisfy({ $0.fits(frame.payload) }),
              spec.sensitive.allSatisfy({ $0.fits(frame.payload) }) else { throw PolicyError.invalidMetadata }
        let applies = spec.applicability
        if let pids = applies.modelPIDs, pids.isDisjoint(with: context.model.pids) { throw PolicyError.modelMismatch }
        if let pids = applies.casePIDs, !pids.contains(context.model.casePID) { throw PolicyError.modelMismatch }
        guard context.permittedComponents.contains(applies.component) else { throw PolicyError.componentUnavailable }
        guard applies.firmware.allows(context.firmwareVersion) else { throw PolicyError.firmwareMismatch }
        func capabilityAvailable(_ key: FeatureKey) -> Bool {
            switch context.capabilities[key] {
            case .supported: return true
            case .readOnly: if case .read = spec.kind { return true }; return false
            default: return false
            }
        }
        guard applies.requiredCapabilities.allSatisfy(capabilityAvailable) else { throw PolicyError.preconditionFailed }
        for condition in spec.preconditions {
            switch condition {
            case .noWorkflow:
                guard !context.workflowActive else { throw PolicyError.preconditionFailed }
            case .componentConnected(let component):
                guard case .connected = context.componentStates[component] else { throw PolicyError.componentUnavailable }
            case .capability(let key):
                guard capabilityAvailable(key) else { throw PolicyError.preconditionFailed }
            }
        }
        let now = ContinuousClock.now
        let payload = Array(frame.payload)
        for field in spec.preservedFields {
            guard let previous = context.preservedFields[field.name],
                  previous.observedAt <= now,
                  previous.observedAt.duration(to: now) <= spec.deadlines.followUpReadback,
                  previous.bytes == Data(payload[field.bytes]) else { throw PolicyError.preservationRequired }
        }
        // Declaration alone never grants the blocked NV family. No standalone
        // reload is possible; atomic engine/capture proofs must precede enabling.
        if spec.nvTransaction != nil { throw PolicyError.unsupported }
    }

    private static func approvedFirmwareRead(_ frame: RaceFrame, spec: OperationSpec,
                                             args: OpArgs, context: PolicyContext) -> Bool {
        let target = ModelCatalog.tourPro3
        guard frame.id == 0x1C07, frame.kind == .command, frame.payload == Data([0]),
              spec.name == TourPro3Reads.firmwareName, args == .none,
              spec.stack == .race, spec.nestedOperation == nil, spec.unwrap == nil,
              spec.responseDeadline > .zero, spec.responseDeadline <= .seconds(5),
              context.model.name == target.name, context.model.pids == target.pids,
              context.model.casePID == target.casePID, context.model.support == .verified,
              case .read = spec.kind,
              case .captured(let fixture, firmwareIndependent: true) = spec.evidence,
              fixture == TourPro3Reads.firmwareFixture,
              case .responseThenIndication(let response, let indication, let kind, let role, let offset) = spec.completion
        else { return false }
        return response == 0x1C07 && indication == 0x1C07 &&
            kind == .notification && role == 0 && offset == 1
    }
}
