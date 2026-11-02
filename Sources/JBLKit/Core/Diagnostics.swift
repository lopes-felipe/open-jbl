import Foundation

public enum ValidationStage: String, Codable, Sendable {
    case policy, connection, baseline, transmission, response, acknowledgement, stateNotification, readback, teardown
}

public enum ValidationRule: String, Codable, Sendable {
    case policyRejected, openFailed, transportFailed, timedOut, cancelled
    case capturedBaseline, capturedAcknowledgement, capturedNotification, capturedReadback, telemetryLayout
}

public struct ValidationFailure: Error, Codable, Sendable, Equatable {
    public let stage: ValidationStage
    public let rule: ValidationRule
    public init(stage: ValidationStage, rule: ValidationRule) { self.stage = stage; self.rule = rule }
}

public struct DiagnosticFrame: Codable, Sendable, Equatable {
    public let type: UInt8
    public let identifier: UInt16
    public let payloadLength: Int
    init(_ frame: RaceFrame) {
        type = frame.kind.rawValue; identifier = frame.id; payloadLength = frame.payload.count
    }
}

public enum DiagnosticResult: String, Codable, Sendable { case started, matched, unmatched, passed, failed }
public enum DiagnosticDirection: String, Codable, Sendable { case inbound, outbound }

/// Values only: no payload, address, name, serial, arbitrary error description or encoder.
public struct DiagnosticEntry: Codable, Sendable, Equatable {
    public let sequence: UInt64
    public let elapsedMilliseconds: Int64
    public let generation: UInt64
    public let operation: String?
    public let stage: ValidationStage
    public let result: DiagnosticResult
    public let direction: DiagnosticDirection?
    public let frame: DiagnosticFrame?
    public let rule: ValidationRule?
}

public struct DiagnosticSnapshot: Codable, Sendable, Equatable {
    public let recording: Bool
    public let overwrittenEntries: UInt64
    public let entries: [DiagnosticEntry]
    public let lastFailure: ValidationFailure?
}

/// Owned synchronously by GuardedSession. Circular storage never exceeds 2,000
/// entries. Consumers poll at most four times per second; ingress never spawns tasks.
struct DiagnosticRing {
    static let capacity = 2_000
    private var storage: [DiagnosticEntry?] = Array(repeating: nil, count: capacity)
    private var next = 0
    private var count = 0
    private var sequence: UInt64 = 0
    private var overwritten: UInt64 = 0
    private(set) var enabled: Bool
    private(set) var lastFailure: ValidationFailure?

    init(enabled: Bool = false) { self.enabled = enabled }
    mutating func clearFailure() { lastFailure = nil }

    mutating func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            storage = Array(repeating: nil, count: Self.capacity)
            next = 0; count = 0; overwritten = 0
        }
    }

    mutating func append(elapsed: Duration, generation: UInt64, operation: String?,
                         stage: ValidationStage, result: DiagnosticResult,
                         direction: DiagnosticDirection? = nil, frame: RaceFrame? = nil,
                         rule: ValidationRule? = nil) {
        if result == .failed, let rule { lastFailure = ValidationFailure(stage: stage, rule: rule) }
        guard enabled else { return }
        sequence &+= 1
        let parts = elapsed.components
        let milliseconds = parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
        let entry = DiagnosticEntry(sequence: sequence, elapsedMilliseconds: milliseconds,
                                    generation: generation, operation: operation, stage: stage,
                                    result: result, direction: direction,
                                    frame: frame.map(DiagnosticFrame.init), rule: rule)
        storage[next] = entry
        next = (next + 1) % Self.capacity
        if count < Self.capacity { count += 1 } else { overwritten &+= 1 }
    }

    func snapshot() -> DiagnosticSnapshot {
        let start = (next - count + Self.capacity) % Self.capacity
        let entries = (0..<count).compactMap { storage[(start + $0) % Self.capacity] }
        return DiagnosticSnapshot(recording: enabled, overwrittenEntries: overwritten,
                                  entries: entries, lastFailure: lastFailure)
    }
}
