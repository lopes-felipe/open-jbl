import Foundation

/// Finite source-defined suites. There is deliberately no public suite/step initializer.
public enum ValidationSuiteID: String, CaseIterable, Codable, Sendable {
    case telemetry
    case ambient
    case anc

    public var title: String {
        switch self {
        case .telemetry: "Captured telemetry"
        case .ambient: "Captured Ambient proof"
        case .anc: "Captured ANC proof"
        }
    }
    public var changesSettings: Bool { self != .telemetry }
    public var preconditions: [String] {
        let common = ["Selected paired Tour Pro 3 already connected in macOS",
                      "Phone JBL app closed", "Do not change settings during the suite"]
        return changesSettings ? common + ["Both buds out of the case and worn", "Ready to hear the selected mode"] : common
    }
    public var operations: [String] {
        switch self {
        case .telemetry: ["earbud-firmware", "case-firmware", "listening-mode", "battery-agent", "battery-partner"]
        case .ambient: ["earbud-firmware", "test-ambient"]
        case .anc: ["earbud-firmware", "test-anc"]
        }
    }
    /// ANC's restoration contract is not verified. No suite silently restores.
    public var restorationOperation: String? { nil }
    public var totalDeadline: Duration { .seconds(changesSettings ? 40 : 45) }
}

public enum ValidationStepOutcome: String, Codable, Sendable {
    case protocolVerified, confirmedChanged, confirmedUnchanged, failed, skipped
}
public enum ValidationObservation: String, CaseIterable, Codable, Sendable {
    case audibleAsExpected, noAudibleChange, uncertain, notObserved
}

public enum ValidationReading: Codable, Sendable, Equatable {
    case firmware(component: String, version: String)
    case battery(role: String, percent: Int)
    case mode(String)
}

public struct ValidationStepResult: Codable, Sendable, Equatable {
    public let operation: String
    public let fixture: String
    public let outcome: ValidationStepOutcome
    public let reading: ValidationReading?
    public let failure: ValidationFailure?
}

public struct ValidationReport: Codable, Sendable, Identifiable {
    public let schemaVersion: Int
    public let id: UUID
    public let suite: ValidationSuiteID
    public let generation: UInt64
    public let build: String
    public let startedAt: Date
    public let finishedAt: Date
    public let earbudFirmware: String?
    public let caseFirmware: String?
    public let steps: [ValidationStepResult]
    public let diagnostics: DiagnosticSnapshot
    public private(set) var observation: ValidationObservation?
    public private(set) var observedAt: Date?

    /// Human observations never rewrite protocol outcomes. A run can be audible
    /// and still have failed its acknowledgement/readback contract.
    public mutating func recordObservation(_ observation: ValidationObservation, at date: Date = Date()) throws {
        guard suite.changesSettings, self.observation == nil else { throw ValidationRunnerError.observationAlreadyRecorded }
        self.observation = observation; observedAt = date
    }

    public var passed: Bool {
        !steps.isEmpty && steps.allSatisfy { $0.outcome != .failed && $0.outcome != .skipped }
    }

    public func json(redactor: Redactor = Redactor()) throws -> Data {
        // Redact decoded string values, so JSON escaping cannot hide a known
        // name/address from matching. No payload is part of this schema.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        func redact(_ value: Any) -> Any {
            if let string = value as? String { return redactor.text(string) }
            if let array = value as? [Any] { return array.map(redact) }
            if let object = value as? [String: Any] { return object.mapValues(redact) }
            return value
        }
        let value = try JSONSerialization.jsonObject(with: encoder.encode(self))
        return try JSONSerialization.data(withJSONObject: redact(value), options: [.prettyPrinted, .sortedKeys])
    }

    public func text(redactor: Redactor = Redactor()) -> String {
        var lines = ["OpenJBL validation \(id.uuidString)", "\(suite.title) • build \(build)",
                     "Generation \(generation) • \(passed ? "protocol checks passed" : "incomplete or failed")",
                     "Earbuds: \(earbudFirmware ?? "Unknown"); case: \(caseFirmware ?? "Unknown")"]
        for step in steps {
            lines.append("\(step.operation): \(step.outcome.rawValue)")
            if let reading = step.reading {
                switch reading {
                case .firmware(let component, let version): lines.append("  \(component): \(version)")
                case .battery(let role, let percent): lines.append("  \(role): \(percent)% (side mapping unverified)")
                case .mode(let mode): lines.append("  Listening mode: \(mode)")
                }
            }
            if let failure = step.failure { lines.append("  Failed \(failure.stage.rawValue): \(failure.rule.rawValue)") }
            lines.append("  Fixture: \(step.fixture)")
        }
        if let failure = diagnostics.lastFailure {
            lines.append("Last diagnostic failure: \(failure.stage.rawValue) / \(failure.rule.rawValue)")
        }
        lines.append("Diagnostic entries: \(diagnostics.entries.count); overwritten: \(diagnostics.overwrittenEntries)")
        lines.append("Human observation: \(observation?.rawValue ?? "not recorded")")
        lines.append("Control link released. No automatic retry or restoration.")
        return redactor.text(lines.joined(separator: "\n"))
    }
}

public enum ValidationRunnerError: Error, Equatable {
    case busy, confirmationRequired, observationAlreadyRecorded
}

/// M1 research orchestration, not the M2 scheduler. The shared guarded session
/// owns all bytes, matching, physical connection guards and operation deadlines.
public actor ValidationRunner {
    private var running = false
    private let deadlineLimit: Duration?
    public init() { deadlineLimit = nil }
    init(deadlineLimit: Duration) { self.deadlineLimit = max(.zero, deadlineLimit) }

    public func run(_ suite: ValidationSuiteID, session: GuardedSession,
                    build: String, prerequisitesConfirmed: Bool = false) async throws -> ValidationReport {
        guard !running else { throw ValidationRunnerError.busy }
        guard !suite.changesSettings || prerequisitesConfirmed else { throw ValidationRunnerError.confirmationRequired }
        running = true
        defer { running = false }
        let startedAt = Date()
        let generation = await session.generation
        let origin = ContinuousClock.now
        let totalDeadline = min(suite.totalDeadline, deadlineLimit ?? suite.totalDeadline)
        var results: [ValidationStepResult] = []
        var stopSequence = false
        var startupFailure: ValidationFailure?
        var versions: (earbuds: String?, chargingCase: String?) = (nil, nil)
        do {
            try Task.checkCancellation()
            try await withDeadline(totalDeadline) { try await session.start() }
        } catch {
            // Another caller already owns this single-use connection. Never
            // tear down its link when this runner failed to acquire ownership.
            if error as? PolicyError == .busy { throw ValidationRunnerError.busy }
            stopSequence = true
            let snapshot = await session.diagnosticSnapshot()
            startupFailure = snapshot.lastFailure ?? ValidationFailure(
                stage: error is PolicyError ? .policy : .connection,
                rule: error is CancellationError ? .cancelled :
                    (error is PolicyError ? .policyRejected : (error as? LinkError == .timedOut ? .timedOut : .openFailed)))
        }
        for name in suite.operations {
            guard let spec = OperationCatalog.production[name],
                  case .captured(let fixture, _) = spec.evidence else {
                // A source-defined suite cannot promote an operation by naming it.
                stopSequence = true
                results.append(ValidationStepResult(operation: name, fixture: "", outcome: .failed,
                                                    reading: nil, failure: ValidationFailure(stage: .policy, rule: .policyRejected)))
                continue
            }
            if let startupFailure, results.isEmpty {
                results.append(ValidationStepResult(operation: name, fixture: fixture, outcome: .failed,
                                                    reading: nil, failure: startupFailure))
                continue
            }
            if stopSequence || Task.isCancelled || origin.duration(to: .now) >= totalDeadline {
                results.append(ValidationStepResult(operation: name, fixture: fixture, outcome: .skipped,
                                                    reading: nil, failure: nil))
                continue
            }
            do {
                let remaining = totalDeadline - origin.duration(to: .now)
                let reply = try await withDeadline(remaining) {
                    try await session.perform(OperationRequest(name))
                }
                let decoded = try Self.validate(reply, operation: name)
                results.append(ValidationStepResult(operation: name, fixture: fixture, outcome: decoded.0,
                                                    reading: decoded.1, failure: nil))
                let observed = await session.observedFirmware()
                versions = (observed.earbuds ?? versions.earbuds, observed.chargingCase ?? versions.chargingCase)
            } catch {
                let snapshot = await session.diagnosticSnapshot()
                let failure: ValidationFailure
                if let typed = error as? ValidationFailure { failure = typed }
                else if error as? LinkError == .timedOut {
                    failure = ValidationFailure(stage: snapshot.lastFailure?.stage ?? .response, rule: .timedOut)
                } else if error is CancellationError || error as? LinkError == .cancelled {
                    failure = ValidationFailure(stage: snapshot.lastFailure?.stage ?? .response, rule: .cancelled)
                } else {
                    failure = snapshot.lastFailure ?? ValidationFailure(stage: .response, rule: .transportFailed)
                }
                results.append(ValidationStepResult(operation: name, fixture: fixture, outcome: .failed,
                                                    reading: nil, failure: failure))
                let observed = await session.observedFirmware()
                versions = (observed.earbuds ?? versions.earbuds, observed.chargingCase ?? versions.chargingCase)
                // Only independent telemetry layout checks may continue on a
                // still-active link. Never reopen or append after stream failure.
                let active = await session.isActive
                stopSequence = suite.changesSettings || !active
            }
        }
        // Capture validated versions before teardown invalidates observations.
        await session.stop()
        return ValidationReport(schemaVersion: 1, id: UUID(), suite: suite, generation: generation,
                                build: String(build.prefix(120)), startedAt: startedAt, finishedAt: Date(),
                                earbudFirmware: versions.earbuds, caseFirmware: versions.chargingCase,
                                steps: results, diagnostics: await session.diagnosticSnapshot())
    }

    private static func validate(_ reply: OperationReply, operation: String) throws -> (ValidationStepOutcome, ValidationReading?) {
        switch reply {
        case .confirmedMode(let mode, let changed):
            guard operation == (mode == .anc ? "test-anc" : "test-ambient") else {
                throw ValidationFailure(stage: .readback, rule: .capturedReadback)
            }
            return (changed ? .confirmedChanged : .confirmedUnchanged, .mode(mode == .anc ? "ANC" : "Ambient"))
        case .response(let frames):
            if operation == "listening-mode",
               let reading = frames.compactMap(TourPro3Sound.decodeListeningReadback).first {
                return (.protocolVerified, .mode(reading.mode == .anc ? "ANC" : "Ambient"))
            }
            guard frames.contains(where: { $0.kind == .response && $0.payload == Data([0]) }) else {
                throw ValidationFailure(stage: .acknowledgement, rule: .capturedAcknowledgement)
            }
            if operation == "earbud-firmware" || operation == "case-firmware",
               let reading = frames.compactMap(TourPro3Telemetry.decodeFirmware).first,
               reading.component == (operation == "earbud-firmware" ? .earbuds : .chargingCase) {
                return (.protocolVerified, .firmware(component: operation == "earbud-firmware" ? "earbuds" : "case",
                                                     version: reading.version))
            }
            if operation == "battery-agent" || operation == "battery-partner",
               let reading = frames.compactMap(TourPro3Telemetry.decodeBattery).first,
               reading.component == (operation == "battery-agent" ? .agent : .partner) {
                return (.protocolVerified, .battery(role: operation == "battery-agent" ? "agent" : "partner",
                                                    percent: reading.percent))
            }
            throw ValidationFailure(stage: .response, rule: .telemetryLayout)
        }
    }
}
