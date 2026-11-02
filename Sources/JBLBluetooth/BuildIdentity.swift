import Foundation
import CryptoKit

public enum BuildIdentity {
    /// Hash the actual app/probe executable; an unchanged marketing version is
    /// insufficient to distinguish validation artifacts.
    public static func current() -> String {
        guard let url = Bundle.main.executableURL, let bytes = try? Data(contentsOf: url) else {
            return "unidentified-build"
        }
        return "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
