import Foundation

/// Payloads are withheld by default. There are no reviewed payload export schemas yet.
/// All app copy/export paths must use this type, never Data.hex directly.
public struct Redactor: Sendable {
    private let secrets: [String]
    public init(secrets: [String] = []) {
        self.secrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    public func text(_ value: String) -> String {
        var result = value
        for secret in secrets {
            result = result.replacingOccurrences(of: secret, with: "<private>", options: .caseInsensitive)
            let byteForms = [Data(secret.utf8)] + ((try? Data(hex: secret)).map { [$0] } ?? [])
            for bytes in byteForms where !bytes.isEmpty {
                for variant in [bytes, Data(bytes.reversed())] {
                    result = result.replacingOccurrences(of: variant.hex, with: "<private>", options: .caseInsensitive)
                    result = result.replacingOccurrences(of: variant.hex.replacingOccurrences(of: " ", with: ""),
                                                        with: "<private>", options: .caseInsensitive)
                    result = result.replacingOccurrences(of: variant.hex.replacingOccurrences(of: " ", with: ":"),
                                                        with: "<private>", options: .caseInsensitive)
                }
            }
        }
        // Also remove addresses not known to the current session.
        result = result.replacingOccurrences(
            of: #"(?i)\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b"#,
            with: "<address>", options: .regularExpression
        )
        return result
    }

    public func frame(_ frame: RaceFrame) -> String {
        String(format: "RACE type=%02X id=%04X <%d bytes>", frame.kind.rawValue, frame.id, frame.payload.count)
    }
}
