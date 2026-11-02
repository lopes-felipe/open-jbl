import Foundation

/// Bounded M1 proof operations, not a general listening-mode driver.
/// The fourth command byte remains opaque, so only complete captured requests
/// are available and the session requires the captured baseline before writing.
enum TourPro3ModeTests {
    static let specs = [
        spec("test-ambient", mode: .ambient, payload: [0, 10, 10, 4]),
        spec("test-anc", mode: .anc, payload: [0, 10, 1, 0])
    ]

    static func target(for name: String) -> TourPro3Sound.ListeningMode? {
        switch name {
        case "test-ambient": .ambient
        case "test-anc": .anc
        default: nil
        }
    }

    static func successfulReply(_ frame: RaceFrame, mode: TourPro3Sound.ListeningMode) -> Bool {
        let echo: [UInt8] = mode == .ambient ? [0, 10, 10, 4, 0, 0] : [0, 10, 1, 0, 0, 0]
        return frame.kind == .response && frame.id == 0x0E06 && frame.payload == Data(echo)
    }

    /// Complete readback profiles observed three times each in session 005.
    /// The final byte's meaning is unknown; do not treat it as a status, level,
    /// or a value that should remain equal across different listening modes.
    static func matchesCapturedProfile(_ report: TourPro3Sound.ListeningReport) -> Bool {
        switch report.mode {
        case .anc: report.opaqueFields == Data([7, 0, 5])
        case .ambient: report.opaqueFields == Data([7, 0, 6])
        }
    }

    private static func spec(_ name: String, mode: TourPro3Sound.ListeningMode,
                             payload: [UInt8]) -> OperationSpec {
        OperationSpec(name: name, kind: .write,
                      evidence: .captured(fixture: "tourpro3/listening-mode-session-003.race.txt",
                                          firmwareIndependent: false),
                      completion: .responseThenIndication(response: 0x0E06, indication: 0x0901,
                                                          kind: .notification, role: mode.rawValue, roleOffset: 3),
                      applicability: OperationApplicability(modelPIDs: ModelCatalog.tourPro3.pids,
                                                           casePIDs: [ModelCatalog.tourPro3.casePID],
                                                           firmware: .exact(["6.0.1"])),
                      preconditions: [.noWorkflow],
                      deadlines: OperationDeadlines(total: .seconds(40)),
                      expectedEffects: [.reconfiguration]) { args in
            guard args == .none else { throw ArgError.invalid }
            return RaceFrame(kind: .command, id: 0x0E06, payload: Data(payload))
        }
    }
}

public enum ModeTestError: Error, Sendable, Equatable {
    case baselineMismatch, acknowledgementMismatch, stateNotificationMismatch, unconfirmed
}
