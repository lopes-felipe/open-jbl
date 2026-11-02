import Foundation
import Testing
@testable import JBLKit

@Suite struct OperationMetadataTests {
    private func spec(kind: OpKind = .read,
                      applicability: OperationApplicability = OperationApplicability(),
                      preconditions: [OperationPrecondition] = [], preservedFields: [FieldRange] = [],
                      deadlines: OperationDeadlines? = nil, correlation: Correlation? = nil,
                      completion: CompletionRule = .response(0x0301),
                      sensitive: [SensitiveField] = [], expectedEffects: [ExpectedEffect] = []) -> OperationSpec {
        OperationSpec(name: "metadata-test", kind: kind,
                      evidence: .captured(fixture: "synthetic-test-only", firmwareIndependent: true),
                      completion: completion, applicability: applicability, correlation: correlation,
                      preconditions: preconditions, preservedFields: preservedFields, deadlines: deadlines,
                      expectedEffects: expectedEffects, sensitive: sensitive) { args in
            guard args == .none else { throw ArgError.invalid }
            return RaceFrame(kind: .command, id: 0x0301, payload: Data([0xAA, 0xBB, 0xCC]))
        }
    }

    private func validate(_ spec: OperationSpec, context: PolicyContext? = nil) throws {
        _ = try SendPolicy.validate(OperationRequest(spec.name), in: OperationCatalog([spec]),
                                    context: context ?? testContext([spec]))
    }

    @Test func productionMetadataIsValidAndDoesNotPromoteAnyOperation() throws {
        #expect(OperationCatalog.production.integrityErrors().isEmpty)
        #expect(ModelCatalog.integrityErrors().isEmpty)
        #expect(OperationCatalog.production.names.count == 7)
        for name in OperationCatalog.production.names {
            let operation = try #require(OperationCatalog.production[name])
            #expect(operation.applicability.modelPIDs == ModelCatalog.tourPro3.pids)
            #expect(operation.applicability.casePIDs == [ModelCatalog.tourPro3.casePID])
            #expect(operation.deadlines.fragmentWrite == .seconds(5))
            #expect(operation.nvTransaction == nil)
        }
        for name in ["test-ambient", "test-anc"] {
            #expect(OperationCatalog.production[name]?.deadlines.total == .seconds(40))
            #expect(throws: PolicyError.firmwareMismatch) {
                try SendPolicy.validate(OperationRequest(name), in: .production,
                                        context: PolicyContext(identityVerified: true, firmwareKnown: true,
                                                               firmwareVersion: "6.0.10"))
            }
            #expect(throws: Never.self) {
                try SendPolicy.validate(OperationRequest(name), in: .production,
                                        context: PolicyContext(identityVerified: true, firmwareKnown: true,
                                                               firmwareVersion: "6.0.1"))
            }
        }
    }

    @Test func everyCapturedProductionEncoderEqualsItsFixtureAndOnlyApprovedIDIsBlocked() throws {
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        var blocked: Set<UInt16> = []
        for name in OperationCatalog.production.names {
            let operation = try #require(OperationCatalog.production[name])
            guard case .captured(let path, _) = operation.evidence else {
                Issue.record("Production operation is missing captured evidence"); continue
            }
            let text = try String(contentsOf: fixtures.appendingPathComponent(path), encoding: .utf8)
            let requests = try text.split(whereSeparator: \.isNewline)
                .filter { $0.hasPrefix("> ") }.map { try Data(hex: String($0.dropFirst(2))) }
            let frame = try operation.encode(.none)
            #expect(try requests.contains(frame.encoded()))
            if Blocklists.race(frame.id) { blocked.insert(frame.id) }
        }
        #expect(blocked == [0x1C07])
    }

    @Test func modelComponentAndFirmwareApplicabilityAreEnforced() throws {
        let wrongPID = spec(applicability: OperationApplicability(modelPIDs: [7]))
        #expect(throws: PolicyError.modelMismatch) { try validate(wrongPID) }
        let wrongCase = spec(applicability: OperationApplicability(casePIDs: [7]))
        #expect(throws: PolicyError.modelMismatch) { try validate(wrongCase) }
        let target = spec(applicability: OperationApplicability(modelPIDs: [1], casePIDs: [2],
                                                               component: .chargingCase, firmware: .prefixes(["6.0."])))
        var context = testContext([target]); context.firmwareVersion = "6.0.1"
        try validate(target, context: context)
        context.permittedComponents = [.earbuds]
        #expect(throws: PolicyError.componentUnavailable) { try validate(target, context: context) }
        context.permittedComponents = [.chargingCase]; context.firmwareVersion = "6.1.0"
        #expect(throws: PolicyError.firmwareMismatch) { try validate(target, context: context) }
        context.firmwareVersion = nil
        #expect(throws: PolicyError.firmwareMismatch) { try validate(target, context: context) }
    }

    @Test func componentAndWorkflowPreconditionsFailClosed() throws {
        let operation = spec(preconditions: [.noWorkflow, .componentConnected(.partner)])
        var context = testContext([operation])
        for state in [ComponentState.unknown, .inCase, .notConnected] {
            context.componentStates[.partner] = state
            #expect(throws: PolicyError.componentUnavailable) { try validate(operation, context: context) }
        }
        context.componentStates[.partner] = .connected
        try validate(operation, context: context)
        context.workflowActive = true
        #expect(throws: PolicyError.preconditionFailed) { try validate(operation, context: context) }
    }

    @Test func capabilityChecksRespectReadOnlyAndUnavailableState() throws {
        let read = spec(applicability: OperationApplicability(requiredCapabilities: [.equalizer]))
        let write = spec(kind: .write, preconditions: [.capability(.equalizer)])
        var context = testContext([read])
        for state in [FeatureAvailability.unknown, .unsupported, .temporarilyUnavailable, .indeterminate] {
            context.capabilities[.equalizer] = state
            #expect(throws: PolicyError.preconditionFailed) { try validate(read, context: context) }
        }
        context.capabilities[.equalizer] = .readOnly
        try validate(read, context: context)
        #expect(throws: PolicyError.preconditionFailed) { try validate(write, context: context) }
        context.capabilities[.equalizer] = .supported
        try validate(write, context: context)
    }

    @Test func preservedFieldsNeedFreshExactDeviceBytesAtDispatch() throws {
        let operation = spec(kind: .write, preservedFields: [FieldRange("unrelated", bytes: 1..<3)])
        var context = testContext([operation])
        #expect(throws: PolicyError.preservationRequired) { try validate(operation, context: context) }
        context.preservedFields["unrelated"] = PreservedFieldValue(bytes: Data([0xBB, 0xCC]))
        try validate(operation, context: context)
        context.preservedFields["unrelated"] = PreservedFieldValue(bytes: Data([0xBB, 0xAA]))
        #expect(throws: PolicyError.preservationRequired) { try validate(operation, context: context) }
        for offset in [Duration.seconds(-6), .seconds(60)] {
            context.preservedFields["unrelated"] = PreservedFieldValue(
                bytes: Data([0xBB, 0xCC]), observedAt: ContinuousClock.now.advanced(by: offset))
            #expect(throws: PolicyError.preservationRequired) { try validate(operation, context: context) }
        }
    }

    @Test func invalidFieldRangesAndMetadataNeverReachTheTransport() {
        let variants = [
            spec(preservedFields: [FieldRange("bad", bytes: -1..<1)]),
            spec(preservedFields: [FieldRange("bad", bytes: 0..<4)]),
            spec(preservedFields: [FieldRange("", bytes: 0..<1)]),
            spec(preservedFields: [FieldRange("a", bytes: 0..<2), FieldRange("b", bytes: 1..<3)]),
            spec(sensitive: [SensitiveField(.serial, bytes: 0..<4)]),
            spec(applicability: OperationApplicability(modelPIDs: [])),
            spec(applicability: OperationApplicability(firmware: .prefixes([""])))
        ]
        for operation in variants {
            #expect(!OperationCatalog([operation]).integrityErrors().isEmpty)
            #expect(throws: PolicyError.invalidMetadata) { try validate(operation) }
        }
    }

    @Test func deadlinesAndDelayedEffectsMustBeBounded() {
        for deadline in [
            OperationDeadlines(response: .zero),
            OperationDeadlines(response: .seconds(31), total: .seconds(40)),
            OperationDeadlines(response: .seconds(5), total: .seconds(4)),
            OperationDeadlines(total: .seconds(121))
        ] {
            #expect(throws: PolicyError.invalidMetadata) { try validate(spec(deadlines: deadline)) }
        }
        for effect in [ExpectedEffect.delayedApplication(maximum: .zero),
                       .delayedApplication(maximum: .seconds(11))] {
            #expect(throws: PolicyError.invalidMetadata) { try validate(spec(expectedEffects: [effect])) }
        }
    }

    @Test func correlationMustMatchTheDeclaredCompletion() throws {
        let completion = CompletionRule.responseThenIndication(
            response: 0x0301, indication: 0x0CD6, kind: .notification, role: 1, roleOffset: 1)
        let inferred = spec(completion: completion)
        try validate(inferred)
        for correlation in [
            Correlation.payloadByte(identifier: 0x0CD6, kind: .notification, offset: -1, value: 1),
            .payloadByte(identifier: 0x0CD6, kind: .notification, offset: 1, value: 0),
            .payloadByte(identifier: 0x0CD6, kind: .indication, offset: 1, value: 1)
        ] {
            #expect(throws: PolicyError.invalidMetadata) { try validate(spec(correlation: correlation, completion: completion)) }
        }
    }

    @Test func nvProofIsExactButNeverOverridesTheCurrentBlocklist() throws {
        let payload = Data([0x42, 0x01, 0xCC])
        let proof = NVTransactionSpec(fixture: "synthetic-test-only", writeIdentifier: 0x0A01,
                                      key: Data([0x42]), keyRange: 0..<1,
                                      values: [Data([1])], valueRange: 1..<2,
                                      capturedPayloads: [payload], reloadPayload: Data([0]))
        #expect(proof.valid)
        #expect(proof.matches(RaceFrame(kind: .command, id: 0x0A01, payload: payload)))
        #expect(!proof.matches(RaceFrame(kind: .command, id: 0x0A01, payload: Data([0x42, 1, 0xDD]))))
        let operation = OperationSpec(
            name: "synthetic-nv", kind: .write,
            evidence: .captured(fixture: "synthetic-test-only", firmwareIndependent: false),
            completion: .response(0x0A01), nvTransaction: proof
        ) { _ in RaceFrame(kind: .command, id: 0x0A01, payload: payload) }
        #expect(OperationCatalog([operation]).integrityErrors().isEmpty)
        #expect(throws: PolicyError.blocked(0x0A01)) { try validate(operation) }
        #expect(throws: PolicyError.blocked(0x0A09)) { try validate(testSpec(0x0A09)) }
    }

    @Test func sensitivePayloadRemainsWithheldRegardlessOfMetadata() throws {
        let operation = spec(sensitive: [SensitiveField(.personalization)])
        try validate(operation)
        let redacted = Redactor().frame(try operation.encode(.none))
        #expect(!redacted.contains("AA BB CC"))
        #expect(redacted.contains("<3 bytes>"))
    }
}
