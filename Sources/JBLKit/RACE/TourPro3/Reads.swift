import Foundation

/// M1 bootstrap reads from session 004. No initialization sequence or settings.
/// These payloads contain only a role or no arguments, with no firmware-specific
/// layout. Replies still require the exact captured telemetry decoder.
enum TourPro3Reads {
    static let fixture = "tourpro3/telemetry-session-004.race.txt"
    static let firmwareName = "earbud-firmware"
    static let firmwareFixture = "tourpro3/earbud-firmware-session-004.race.txt"
    static let specs: [OperationSpec] = [
        OperationSpec(name: firmwareName, kind: .read,
                      evidence: .captured(fixture: firmwareFixture, firmwareIndependent: true),
                      completion: .responseThenIndication(response: 0x1C07, indication: 0x1C07,
                                                          kind: .notification, role: 0, roleOffset: 1),
                      applicability: applicability(.earbuds)) { args in
            guard args == .none else { throw ArgError.invalid }
            return RaceFrame(kind: .command, id: 0x1C07, payload: Data([0]))
        },
        battery("battery-agent", role: 0),
        battery("battery-partner", role: 1),
        OperationSpec(name: "listening-mode", kind: .read,
                      evidence: .captured(fixture: "tourpro3/listening-read-session-004.race.txt",
                                          firmwareIndependent: true),
                      completion: .response(0x0901),
                      applicability: applicability(.earbuds)) { args in
            guard args == .none else { throw ArgError.invalid }
            return RaceFrame(kind: .command, id: 0x0901, payload: Data([5, 0]))
        },
        OperationSpec(name: "case-firmware", kind: .read,
                      evidence: .captured(fixture: fixture, firmwareIndependent: true),
                      completion: .responseThenIndication(response: 0x000F, indication: 0x000F,
                                                          kind: .notification, role: nil),
                      applicability: applicability(.chargingCase)) { args in
            guard args == .none else { throw ArgError.invalid }
            return RaceFrame(kind: .command, id: 0x000F)
        }
    ]

    private static func battery(_ name: String, role: UInt8) -> OperationSpec {
        OperationSpec(name: name, kind: .read,
                      evidence: .captured(fixture: fixture, firmwareIndependent: true),
                      completion: .responseThenIndication(response: 0x0CD6, indication: 0x0CD6,
                                                          kind: .notification, role: role, roleOffset: 1),
                      applicability: applicability(role == 0 ? .earbuds : .partner)) { args in
            guard args == .none else { throw ArgError.invalid }
            return RaceFrame(kind: .command, id: 0x0CD6, payload: Data([role]))
        }
    }

    private static func applicability(_ component: OperationComponent) -> OperationApplicability {
        OperationApplicability(modelPIDs: ModelCatalog.tourPro3.pids,
                               casePIDs: [ModelCatalog.tourPro3.casePID], component: component)
    }
}
