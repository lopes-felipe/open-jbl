import Foundation

/// The passive listening report layout observed in session 003. This does not
/// establish identity, capabilities, firmware independence or write arguments.
public enum TourPro3Sound {
    public enum ListeningMode: UInt8, Sendable {
        case anc = 0x01
        case ambient = 0x0A
    }

    public struct ListeningReport: Sendable, Equatable {
        public let mode: ListeningMode
        /// Meaning/range not established. Preserve rather than reinterpret.
        public let opaqueFields: Data
    }

    public static func decodeListeningReport(_ frame: RaceFrame) -> ListeningReport? {
        guard frame.kind == .notification, frame.id == 0x0901 else { return nil }
        let bytes = [UInt8](frame.payload)
        guard bytes.count == 6, Array(bytes.prefix(3)) == [5, 0, 0],
              let mode = ListeningMode(rawValue: bytes[3]) else { return nil }
        return ListeningReport(mode: mode, opaqueFields: Data(bytes.suffix(2)))
    }

    /// The captured module-5 query returns state directly in 5B, with one more
    /// opaque byte than the 5D push layout. That suffix is not an ACK status.
    public static func decodeListeningReadback(_ frame: RaceFrame) -> ListeningReport? {
        guard frame.kind == .response, frame.id == 0x0901 else { return nil }
        let bytes = [UInt8](frame.payload)
        guard bytes.count == 7, Array(bytes.prefix(3)) == [5, 0, 0],
              let mode = ListeningMode(rawValue: bytes[3]) else { return nil }
        return ListeningReport(mode: mode, opaqueFields: Data(bytes.suffix(3)))
    }
}
