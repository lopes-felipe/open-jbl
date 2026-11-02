import Foundation
import Testing
@testable import JBLKit

@Suite struct ValidationTests {
    private func permit() -> AcquisitionPermit {
        AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
    }
    private func exchange(_ name: String, _ replies: [RaceFrame]) throws -> ResearchExchange {
        ResearchExchange(request: try #require(OperationCatalog.production[name]).encode(.none), replies: replies)
    }
    private func firmware() throws -> ResearchExchange {
        try exchange("earbud-firmware", [
            RaceFrame(kind: .response, id: 0x1C07, payload: Data([0])),
            RaceFrame(kind: .notification, id: 0x1C07, payload: Data([0, 0, 6]) + Data("v6.0.1".utf8))
        ])
    }
    private func mode(_ mode: UInt8 = 1) throws -> ResearchExchange {
        try exchange("listening-mode", [
            RaceFrame(kind: .response, id: 0x0901, payload: Data([5, 0, 0, mode, 7, 0, mode == 1 ? 5 : 6]))
        ])
    }

    @Test func boundedRingRetainsNewestInOrderAndNeverStoresPayload() throws {
        var ring = DiagnosticRing(enabled: true)
        let secret = Data("SERIAL-private 11:22:33:44:55:66".utf8)
        for index in 0..<2_150 {
            ring.append(elapsed: .milliseconds(index), generation: 4, operation: nil, stage: .response,
                        result: .unmatched, direction: .inbound,
                        frame: RaceFrame(kind: .notification, id: 0x6789, payload: secret))
        }
        let snapshot = ring.snapshot()
        #expect(snapshot.entries.count == 2_000)
        #expect(snapshot.overwrittenEntries == 150)
        #expect(snapshot.entries.first?.sequence == 151)
        #expect(snapshot.entries.last?.sequence == 2_150)
        #expect(snapshot.entries.first?.elapsedMilliseconds == 150)
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!json.contains("SERIAL-private"))
        #expect(!json.contains("11:22"))
        #expect(json.contains("payloadLength"))
        ring.setEnabled(false)
        ring.append(elapsed: .seconds(3), generation: 4, operation: nil, stage: .readback,
                    result: .failed, rule: .capturedReadback)
        #expect(ring.snapshot().entries.isEmpty)
        #expect(ring.snapshot().lastFailure == ValidationFailure(stage: .readback, rule: .capturedReadback))
    }

    @Test func telemetrySuiteUsesOneAcquisitionAndAllTypedDecoders() async throws {
        let caseRead = try exchange("case-firmware", [
            RaceFrame(kind: .response, id: 0x000F, payload: Data([0])),
            RaceFrame(kind: .notification, id: 0x000F, payload: Data([0]) + Data("5.7.0".utf8))
        ])
        func battery(_ role: UInt8, percent: UInt8) throws -> ResearchExchange {
            try exchange(role == 0 ? "battery-agent" : "battery-partner", [
                RaceFrame(kind: .response, id: 0x0CD6, payload: Data([0])),
                RaceFrame(kind: .notification, id: 0x0CD6, payload: Data([0, role, percent]))
            ])
        }
        let link = ResearchLink(try [firmware(), caseRead, mode(), battery(0, percent: 45), battery(1, percent: 49)])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext(), recordDiagnostics: true)
        let report = try await ValidationRunner().run(.telemetry, session: session, build: "test-artifact")
        #expect(report.passed)
        #expect(link.openCount == 1)
        #expect(link.isClosed)
        #expect(link.writes.count == 5)
        #expect(report.earbudFirmware == "6.0.1")
        #expect(report.caseFirmware == "5.7.0")
        #expect(report.steps.last?.reading == .battery(role: "partner", percent: 49))
        #expect(!report.diagnostics.entries.isEmpty)
        #expect(report.steps.allSatisfy { !$0.fixture.isEmpty })
        #expect(try JSONSerialization.jsonObject(with: report.json()) is [String: Any])
    }

    @Test func modeRequiresConfirmationBeforeOpening() async throws {
        let link = ResearchLink([])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext())
        await #expect(throws: ValidationRunnerError.confirmationRequired) {
            try await ValidationRunner().run(.ambient, session: session, build: "test")
        }
        #expect(link.openCount == 0)
        #expect(link.writes.isEmpty)
    }

    @Test func competingRunnerCannotCloseAnOwnedConnection() async throws {
        let link = ResearchLink(try [mode()])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext())
        try await session.start()
        await #expect(throws: ValidationRunnerError.busy) {
            try await ValidationRunner().run(.telemetry, session: session, build: "test")
        }
        #expect(link.openCount == 1)
        #expect(!link.isClosed)
        #expect(link.writes.isEmpty)
        _ = try await session.perform(OperationRequest("listening-mode"))
        #expect(link.writes.count == 1)
        await session.stop()
    }

    @Test(arguments: [true, false])
    func failedModePreservesExactFailureStageAndNeverRestores(badAck: Bool) async throws {
        let ack = RaceFrame(kind: .response, id: 0x0E06,
                            payload: Data([0, 10, 10, 4, badAck ? 1 : 0, 0]))
        let state = RaceFrame(kind: .notification, id: 0x0901,
                              payload: Data([5, 0, 0, 10, badAck ? 7 : 8, 0]))
        let setting = try exchange("test-ambient", [state, ack])
        let link = ResearchLink(try [firmware(), mode(), setting])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext(), recordDiagnostics: true)
        var report = try await ValidationRunner().run(.ambient, session: session, build: "Secret \"Host\"\n",
                                                     prerequisitesConfirmed: true)
        #expect(!report.passed)
        let failure = try #require(report.steps.last?.failure)
        #expect(failure.stage == (badAck ? .acknowledgement : .stateNotification))
        #expect(failure.rule == (badAck ? .capturedAcknowledgement : .capturedNotification))
        #expect(report.earbudFirmware == "6.0.1") // teardown must not erase the run's baseline
        #expect(link.isClosed)
        #expect(link.writes.map(\.id) == [0x1C07, 0x0901, 0x0E06])
        #expect(ValidationSuiteID.ambient.restorationOperation == nil)
        try report.recordObservation(.audibleAsExpected)
        #expect(!report.passed)
        #expect(throws: ValidationRunnerError.observationAlreadyRecorded) {
            try report.recordObservation(.noAudibleChange)
        }
        let redacted = String(decoding: try report.json(redactor: Redactor(secrets: ["Secret \"Host\"\n"])), as: UTF8.self)
        #expect(!redacted.contains("Secret"))
        #expect(redacted.contains("<private>"))
    }

    @Test func independentReadLayoutFailureContinuesWithoutAnotherOpen() async throws {
        let link = ResearchLink(try [
            firmware(),
            exchange("case-firmware", [RaceFrame(kind: .response, id: 0x000F, payload: Data([0])),
                                      RaceFrame(kind: .notification, id: 0x000F, payload: Data([0, 99]))]),
            mode(),
            exchange("battery-agent", [RaceFrame(kind: .response, id: 0x0CD6, payload: Data([0])),
                                       RaceFrame(kind: .notification, id: 0x0CD6, payload: Data([0, 0, 45]))]),
            exchange("battery-partner", [RaceFrame(kind: .response, id: 0x0CD6, payload: Data([0])),
                                         RaceFrame(kind: .notification, id: 0x0CD6, payload: Data([0, 1, 49]))])
        ])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext())
        let report = try await ValidationRunner().run(.telemetry, session: session, build: "test")
        #expect(report.steps[1].failure?.rule == .telemetryLayout)
        #expect(report.steps.last?.outcome == .protocolVerified)
        #expect(link.openCount == 1)
        #expect(report.diagnostics.entries.isEmpty) // recording is opt-in
    }

    @Test func cancellationBeforeRunOpensNothingAndReturnsIncompleteReport() async throws {
        let link = ResearchLink([])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext())
        let ready = PendingSlot<Void>()
        let task = Task {
            try? await ready.wait()
            return try await ValidationRunner().run(.telemetry, session: session, build: "test")
        }
        task.cancel()
        ready.finish(.success(()))
        let report = try await task.value
        #expect(!report.passed)
        #expect(link.openCount == 0)
        #expect(link.writes.isEmpty)
        #expect(link.isClosed)
        #expect(report.steps.first?.failure?.rule == .cancelled)
    }

    @Test func revokedPermitIsARecordedFailureBeforeAnyOpen() async throws {
        let link = ResearchLink([])
        let revoked = AcquisitionPermit(AcquisitionContext(selectedAndPaired: false, classicConnected: false,
                                                           controlNeeded: false))
        let session = GuardedSession(link: link, permit: revoked, context: PolicyContext())
        let report = try await ValidationRunner().run(.telemetry, session: session, build: "test")
        #expect(report.steps.first?.outcome == .failed)
        #expect(report.steps.first?.failure == ValidationFailure(stage: .policy, rule: .policyRejected))
        #expect(report.steps.dropFirst().allSatisfy { $0.outcome == .skipped })
        #expect(link.openCount == 0)
        #expect(link.writes.isEmpty)
    }

    @Test func suiteDeadlineReportsTimeoutRatherThanCleanupCancellation() async throws {
        let link = ResearchLink(try [firmware()], pauseAt: 1)
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext(), recordDiagnostics: true)
        let report = try await ValidationRunner(deadlineLimit: .milliseconds(30))
            .run(.telemetry, session: session, build: "test")
        #expect(report.steps.first?.outcome == .failed)
        #expect(report.steps.first?.failure?.rule == .timedOut)
        #expect(report.steps.dropFirst().allSatisfy { $0.outcome == .skipped })
        #expect(link.isClosed)
        #expect(link.writes.count == 1)
    }

    @Test func stateIngressIsOrderedAndSingleAttachment() async throws {
        let response = RaceFrame(kind: .response, id: 0x0901, payload: Data([5, 0, 0, 1, 7, 0, 5]))
        let push = RaceFrame(kind: .notification, id: 0x0CD6, payload: Data([0, 0, 45]))
        let link = ResearchLink(try [exchange("listening-mode", [push, response])])
        let session = GuardedSession(link: link, permit: permit(), context: PolicyContext())
        let mailbox = try await session.attachStateEvents()
        await #expect(throws: LinkError.multipleConsumers) { try await session.attachStateEvents() }
        try await session.start()
        _ = try await session.perform(OperationRequest("listening-mode"))
        let first = try #require(await mailbox.next())
        let second = try #require(await mailbox.next())
        #expect(first.sequence < second.sequence)
        #expect(first.generation == link.generation)
        #expect(first.event == .data(.control, try push.encoded()))
        #expect(second.event == .data(.control, try response.encoded()))
        await session.stop()
        #expect(try await mailbox.next()?.event == .closed(.disconnected))
    }
}
