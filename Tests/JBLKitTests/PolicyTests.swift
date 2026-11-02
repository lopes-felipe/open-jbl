import Foundation
import Testing
@testable import JBLKit

func testSpec(_ id: UInt16 = 0x0301, name: String = "synthetic",
              kind: OpKind = .read, evidence: Evidence = .captured(fixture: "synthetic-test-only", firmwareIndependent: true),
              completion: CompletionRule? = nil, deadline: Duration = .seconds(1)) -> OperationSpec {
    OperationSpec(name: name, kind: kind, evidence: evidence,
                  completion: completion ?? .response(id), responseDeadline: deadline) { args in
        guard args == .none else { throw ArgError.invalid }
        return RaceFrame(kind: .command, id: id)
    }
}

func testContext(_ specs: [OperationSpec], verified: Bool = true, firmwareKnown: Bool = true,
                 support: SupportLevel = .verified, experimental: Bool = false) -> PolicyContext {
    let model = ModelInfo(name: "Synthetic test device", pids: [1], casePID: 2, stack: .race,
                          support: support, enabledOperations: Set(specs.map(\.name)), features: [:])
    return PolicyContext(model: model, identityVerified: verified, firmwareKnown: firmwareKnown,
                         allowExperimentalChanges: experimental)
}

@Suite struct PolicyTests {
    @Test func otherFirmwareSpecsRemainBlockedAndEmitNoBytes() async throws {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let text = try String(contentsOf: root.appendingPathComponent(
            "tourpro3/earbud-firmware-session-004.race.txt"), encoding: .utf8)
        let line = try #require(text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("> ") })
        let bytes = try Data(hex: String(line.dropFirst(2)))
        let spec = OperationSpec(name: "blocked-earbud-firmware", kind: .read,
            evidence: .captured(fixture: "tourpro3/earbud-firmware-session-004.race.txt",
                                firmwareIndependent: true), completion: .response(0x1C07)) { args in
                guard args == .none else { throw ArgError.invalid }
                return RaceFrame(kind: .command, id: 0x1C07, payload: Data([0]))
            }
        #expect(try spec.encode(.none).encoded() == bytes)
        #expect(OperationCatalog.production[spec.name] == nil)
        let link = FakeLink()
        let permit = AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
        let session = GuardedSession(link: link, permit: permit, context: testContext([spec]),
                                     catalog: OperationCatalog([spec]))
        try await session.start()
        await #expect(throws: PolicyError.blocked(0x1C07)) {
            try await session.perform(OperationRequest(spec.name))
        }
        #expect(link.writes.isEmpty)
        await session.stop()
    }

    @Test func productionResearchWritesRemainIdentityAndFirmwareGated() {
        let readNames = ["battery-agent", "battery-partner", "case-firmware", "listening-mode", "earbud-firmware"]
        #expect(Set(OperationCatalog.production.names) == Set(readNames + ["test-ambient", "test-anc"]))
        #expect(ModelCatalog.tourPro3.enabledOperations == Set(OperationCatalog.production.names))
        for name in readNames {
            guard let spec = OperationCatalog.production[name] else { Issue.record("Missing spec"); continue }
            guard case .read = spec.kind else { Issue.record("Non-read in bootstrap catalog"); continue }
            #expect(throws: Never.self) {
                try SendPolicy.validate(OperationRequest(name), in: .production, context: PolicyContext())
            }
            #expect(throws: PolicyError.invalidArguments) {
                try SendPolicy.validate(OperationRequest(name, args: .int(0)), in: .production, context: PolicyContext())
            }
        }
        for name in ["test-ambient", "test-anc"] {
            #expect(throws: PolicyError.identityRequired) {
                try SendPolicy.validate(OperationRequest(name), in: .production, context: PolicyContext())
            }
            #expect(throws: PolicyError.unknownFirmware) {
                try SendPolicy.validate(OperationRequest(name), in: .production,
                                        context: PolicyContext(identityVerified: true))
            }
        }
        #expect(ModelCatalog.integrityErrors().isEmpty)
        #expect(throws: PolicyError.unknownOperation) {
            try SendPolicy.validate(OperationRequest("liveness"), in: .production, context: PolicyContext())
        }
    }

    @Test func firmwareExceptionRejectsOtherPayloadsAndContracts() throws {
        let approved = try #require(OperationCatalog.production["earbud-firmware"])
        func variant(payload: Data = Data([0]), kind: OpKind = .read,
                     evidence: Evidence? = nil, completion: CompletionRule? = nil,
                     deadline: Duration = .seconds(5)) -> OperationSpec {
            OperationSpec(name: approved.name, kind: kind, evidence: evidence ?? approved.evidence,
                          completion: completion ?? approved.completion, responseDeadline: deadline) { args in
                guard args == .none else { throw ArgError.invalid }
                return RaceFrame(kind: .command, id: 0x1C07, payload: payload)
            }
        }
        let payloads = [Data(), Data([0, 0])] + (1...255).map { Data([UInt8($0)]) }
        let variants = payloads.map { variant(payload: $0) } + [
            variant(kind: .write),
            variant(kind: .heartbeat),
            variant(evidence: .captured(fixture: "another-model.race.txt", firmwareIndependent: true)),
            variant(evidence: .captured(fixture: TourPro3Reads.firmwareFixture, firmwareIndependent: false)),
            variant(completion: .response(0x1C07)),
            variant(completion: .responseThenIndication(response: 0x1C07, indication: 0x1C07,
                                                       kind: .notification, role: 1, roleOffset: 1)),
            variant(deadline: .zero), variant(deadline: .seconds(6))
        ]
        for spec in variants {
            #expect(throws: PolicyError.blocked(0x1C07)) {
                try SendPolicy.validate(OperationRequest(spec.name), in: OperationCatalog([spec]),
                                        context: PolicyContext(identityVerified: true, firmwareKnown: true))
            }
        }
        let target = ModelCatalog.tourPro3
        let models = [
            ModelInfo(name: "Another Airoha model", pids: target.pids, casePID: target.casePID,
                      stack: .race, support: .verified, enabledOperations: target.enabledOperations, features: [:]),
            ModelInfo(name: target.name, pids: [0x20F1], casePID: target.casePID,
                      stack: .race, support: .verified, enabledOperations: target.enabledOperations, features: [:]),
            ModelInfo(name: target.name, pids: target.pids, casePID: 0x20FC,
                      stack: .race, support: .verified, enabledOperations: target.enabledOperations, features: [:]),
            ModelInfo(name: target.name, pids: target.pids, casePID: target.casePID,
                      stack: .race, support: .experimental, enabledOperations: target.enabledOperations, features: [:])
        ]
        for model in models {
            #expect(throws: PolicyError.blocked(0x1C07)) {
                try SendPolicy.validate(OperationRequest(approved.name), in: .production,
                                        context: PolicyContext(model: model))
            }
        }
        #expect(Blocklists.race(0x1C07)) // exception never removes the general deny
    }

    @Test func firmwareExceptionNeverAppliesInsideWrappers() throws {
        let inner = try #require(OperationCatalog.production["earbud-firmware"])
        let target = ModelCatalog.tourPro3
        for id: UInt16 in [0x0D01, 0x0093] {
            let outer = OperationSpec(name: "wrapped-firmware", kind: .read,
                evidence: .captured(fixture: "synthetic-test-only", firmwareIndependent: true),
                completion: .response(id), nestedOperation: inner.name, unwrap: { $0 }) { args in
                    RaceFrame(kind: .command, id: id, payload: try inner.encode(args).encoded())
                }
            let model = ModelInfo(name: target.name, pids: target.pids, casePID: target.casePID,
                                  stack: .race, support: .verified,
                                  enabledOperations: target.enabledOperations.union([outer.name]), features: [:])
            #expect(throws: PolicyError.blocked(0x1C07)) {
                try SendPolicy.validate(OperationRequest(outer.name), in: OperationCatalog([outer, inner]),
                                        context: PolicyContext(model: model))
            }
        }
    }

    @Test func evidenceForReadsAndWrites() {
        for kind in [OpKind.read, .write, .heartbeat, .action(.audible)] {
            for evidence in [Evidence.none, .documented(source: "other model")] {
                let spec = testSpec(kind: kind, evidence: evidence)
                #expect(throws: (any Error).self) {
                    try SendPolicy.validate(OperationRequest(spec.name), in: OperationCatalog([spec]),
                                            context: testContext([spec]))
                }
            }
        }
    }

    @Test func identityAndExperimentalPolicy() {
        let captured = testSpec(kind: .write)
        #expect(throws: PolicyError.identityRequired) {
            try SendPolicy.validate(OperationRequest(captured.name), in: OperationCatalog([captured]),
                                    context: testContext([captured], verified: false))
        }
        let documented = testSpec(kind: .write, evidence: .documented(source: "test"))
        #expect(throws: PolicyError.experimentalDisabled) {
            try SendPolicy.validate(OperationRequest(documented.name), in: OperationCatalog([documented]),
                                    context: testContext([documented], support: .experimental))
        }
        #expect(throws: Never.self) {
            try SendPolicy.validate(OperationRequest(documented.name), in: OperationCatalog([documented]),
                                    context: testContext([documented], support: .experimental, experimental: true))
        }
    }

    @Test func unknownFirmwareOnlyIndependentReads() {
        let read = testSpec()
        #expect(throws: Never.self) {
            try SendPolicy.validate(OperationRequest(read.name), in: OperationCatalog([read]),
                                    context: testContext([read], firmwareKnown: false))
        }
        for spec in [testSpec(kind: .write),
                     testSpec(evidence: .captured(fixture: "test", firmwareIndependent: false))] {
            #expect(throws: PolicyError.unknownFirmware) {
                try SendPolicy.validate(OperationRequest(spec.name), in: OperationCatalog([spec]),
                                        context: testContext([spec], firmwareKnown: false))
            }
        }
    }

    @Test func argsAndConfirmation() {
        let spec = testSpec(kind: .action(.audible))
        let catalog = OperationCatalog([spec])
        let context = testContext([spec])
        #expect(throws: PolicyError.invalidArguments) {
            try SendPolicy.validate(OperationRequest(spec.name, args: .int(-1)), in: catalog, context: context)
        }
        #expect(throws: PolicyError.confirmationRequired) {
            try SendPolicy.validate(OperationRequest(spec.name), in: catalog, context: context)
        }
        #expect(throws: PolicyError.confirmationRequired) {
            try SendPolicy.validate(OperationRequest(spec.name, confirmation: ConfirmationToken(userConfirmed: "other")),
                                    in: catalog, context: context)
        }
        #expect(throws: Never.self) {
            try SendPolicy.validate(OperationRequest(spec.name, confirmation: ConfirmationToken(userConfirmed: spec.name)),
                                    in: catalog, context: context)
        }
    }

    @Test func everyRaceBlocklistedID() {
        let ranges = Array(UInt16(0x1C00)...0x1C1B) + Array(UInt16(0x0400)...0x04F0) +
            Array(UInt16(0x0702)...0x070F) + Array(UInt16(0x1E00)...0x1E15)
        let singles: [UInt16] = [
            0x0A01, 0x0A03, 0x0A09, 0x0A0A, 0x0A0D, 0x020D, 0x0E01, 0x0E02,
            0x0E0A, 0x0E0B, 0x1101, 0x0CC0, 0x0CD5, 0x1680, 0x0CD7, 0x2C86,
            0x3101, 0x0057, 0x0067, 0x0007, 0x0011, 0x0083, 0x0089, 0x0094, 0x0030
        ]
        for id in ranges + singles {
            let spec = testSpec(id)
            #expect(throws: PolicyError.blocked(id)) {
                try SendPolicy.validate(OperationRequest(spec.name), in: OperationCatalog([spec]), context: testContext([spec]))
            }
        }
        #expect(!Blocklists.race(0x0301))
    }

    @Test func relayBlocklistAndDoubleNesting() throws {
        for id: UInt16 in [0x0A09, 0x0400, 0x0D01, 0x0093] {
            let inner = testSpec(id, name: "inner")
            let outer = OperationSpec(name: "outer", kind: .read,
                evidence: .captured(fixture: "test", firmwareIndependent: true),
                completion: .response(0x0D01), nestedOperation: "inner", unwrap: { $0 }) { _ in
                    RaceFrame(kind: .command, id: 0x0D01, payload: try inner.encode(.none).encoded())
                }
            #expect(throws: (any Error).self) {
                try SendPolicy.validate(OperationRequest("outer"), in: OperationCatalog([inner, outer]),
                                        context: testContext([inner, outer]))
            }
        }
    }

    @Test func relayCannotSmuggleWriteThroughRead() {
        let inner = testSpec(name: "inner", kind: .write)
        let outer = OperationSpec(name: "outer", kind: .read,
            evidence: .captured(fixture: "test", firmwareIndependent: true), completion: .response(0x0D01),
            nestedOperation: "inner", unwrap: { $0 }) { _ in
                RaceFrame(kind: .command, id: 0x0D01, payload: try inner.encode(.none).encoded())
            }
        #expect(throws: PolicyError.nestedMessage) {
            try SendPolicy.validate(OperationRequest("outer"), in: OperationCatalog([inner, outer]),
                                    context: testContext([inner, outer], verified: false))
        }
    }

    @Test func relayCannotDowngradeFirmwareApplicability() {
        let inner = testSpec(name: "inner", evidence: .captured(fixture: "test", firmwareIndependent: false))
        let outer = OperationSpec(name: "outer", kind: .read,
            evidence: .captured(fixture: "test", firmwareIndependent: true), completion: .response(0x0D01),
            nestedOperation: "inner", unwrap: { $0 }) { _ in
                RaceFrame(kind: .command, id: 0x0D01, payload: try inner.encode(.none).encoded())
            }
        #expect(throws: PolicyError.unknownFirmware) {
            try SendPolicy.validate(OperationRequest("outer"), in: OperationCatalog([inner, outer]),
                                    context: testContext([inner, outer], firmwareKnown: false))
        }
    }

    @Test func aaAndP4DefenseInDepth() {
        for id: UInt8 in [0x95, 0x97, 0xF0, 0x15, 0x74, 0x61] { #expect(Blocklists.aa(id, payload: Data())) }
        #expect(Blocklists.aa(0xA3, payload: Data([3])))
        #expect(Blocklists.aa(0x21, payload: Data([0x37])))
        #expect(!Blocklists.aa(0x25, payload: Data([0])))
        #expect(Blocklists.p4(command: 0, feature: 0x1F00, isSet: false, handshake: true))
        #expect(Blocklists.p4(command: 0, feature: 7, isSet: true, handshake: false))
        #expect(!Blocklists.p4(command: 0, feature: 7, isSet: true, handshake: true))
    }

    @Test func allConnectionConditionsRequired() {
        let good = AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true)
        #expect(good.allowsAcquisition)
        for i in 0..<6 {
            var value = good
            switch i {
            case 0: value.selectedAndPaired = false
            case 1: value.classicConnected = false
            case 2: value.controlNeeded = false
            case 3: value.awake = false
            case 4: value.permitted = false
            default: value.released = true
            }
            #expect(!value.allowsAcquisition)
        }
    }
}
