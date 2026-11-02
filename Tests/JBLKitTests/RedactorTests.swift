import Foundation
import Testing
@testable import JBLKit

@Suite struct RedactorTests {
    @Test func masksKnownIdentityAndReverseHex() {
        let redactor = Redactor(secrets: ["11:22:33:44:55:66", "SERIAL123456", "Alice’s Mac", "JBL Tour Pro 3"])
        let input = "11:22:33:44:55:66 / 11 22 33 44 55 66 / 66 55 44 33 22 11 / SERIAL123456 / Alice’s Mac / JBL Tour Pro 3"
        let output = redactor.text(input)
        #expect(!output.contains("11:22"))
        #expect(!output.contains("11 22"))
        #expect(!output.contains("66 55"))
        #expect(!output.contains("SERIAL123456"))
        #expect(!output.contains("Alice"))
        #expect(!output.contains("JBL"))
        let serial = Data("SERIAL123456".utf8)
        #expect(redactor.text(serial.hex) == "<private>")
        #expect(redactor.text(Data(serial.reversed()).hex) == "<private>")
    }
    @Test func unknownAndPersonalizationNeverExportPayload() throws {
        for id: UInt16 in [0x0062, 0x0063, 0x0D01, 0x0093, 0xFFFF] {
            let secret = Data("SERIAL123456".utf8)
            let frame = RaceFrame(kind: .indication, id: id, payload: secret)
            let output = Redactor().frame(frame)
            #expect(!output.contains("SERIAL"))
            #expect(!output.contains(secret.hex))
            #expect(output.contains("<12 bytes>"))
        }
    }
}
