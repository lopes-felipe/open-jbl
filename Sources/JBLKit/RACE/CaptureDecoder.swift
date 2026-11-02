import Foundation

public struct CaptureRecord: Sendable {
    public let timestamp: String
    public let direction: String
    public let source: String
    public let frame: RaceFrame
}

/// Decodes tshark TSV without transmitting. Keeps independent direction/CID/handle
/// streams, and never concatenates ATT, SPP and raw L2CAP representations.
public enum CaptureDecoder {
    public static func decode(_ tsv: String) throws -> [CaptureRecord] {
        var decoders: [String: RaceCodec] = [:]
        var records: [CaptureRecord] = []
        for line in tsv.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("frame.time_relative") || line.hasPrefix("#") { continue }
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cells.count == 8, let seconds = Double(cells[0]), seconds.isFinite, seconds >= 0,
                  seconds < 1_000_000_000 else { throw CaptureError.invalidTSV }
            let source: String
            let payload: String
            if !cells[5].isEmpty { source = "ATT:\(cells[4])"; payload = cells[5] }
            else if !cells[6].isEmpty { source = "SPP"; payload = cells[6] }
            else { source = "L2CAP"; payload = cells[7] }
            if payload.isEmpty { continue }
            let bytes = try Data(hex: payload)
            // Mid-connection traces can lack the L2CAP negotiation that lets
            // tshark recognize ATT on dynamic Classic channels. Classify only
            // a complete Write Command/Notification containing one exact frame.
            // This remains a candidate: no service, peer or identity is inferred.
            if source == "L2CAP", let candidate = attCandidate(bytes) {
                records.append(CaptureRecord(timestamp: cells[0], direction: cells[1],
                    source: String(format: "ATT-candidate:0x%04x", candidate.handle),
                    frame: candidate.frame))
                continue
            }
            let key = "\(cells[1])/\(cells[2])/\(source)"
            var decoder = decoders[key] ?? RaceCodec()
            let now = Duration.milliseconds(Int64(seconds * 1000))
            // Offline expiry discards the previous partial packet and then resumes.
            if (try? decoder.expire(at: now)) == nil { decoder.reset() }
            for frame in try decoder.ingest(bytes, at: now) {
                records.append(CaptureRecord(timestamp: cells[0], direction: cells[1], source: source, frame: frame))
            }
            decoders[key] = decoder
        }
        return records
    }

    private static func attCandidate(_ bytes: Data) -> (handle: UInt16, frame: RaceFrame)? {
        let values = [UInt8](bytes)
        guard values.count >= 9, values[0] == 0x52 || values[0] == 0x1B else { return nil }
        let handle = UInt16(values[1]) | UInt16(values[2]) << 8
        guard handle != 0, let frame = try? RaceFrame.exact(Data(values.dropFirst(3))) else { return nil }
        return (handle, frame)
    }
}
public enum CaptureError: Error { case invalidTSV }
