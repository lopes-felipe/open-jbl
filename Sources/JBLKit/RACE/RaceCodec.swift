import Foundation

public struct RaceFrame: Sendable, Equatable {
    public enum Kind: UInt8, CaseIterable, Sendable { case command = 0x5A, response, indication, notification }
    public let kind: Kind
    public let id: UInt16
    public let payload: Data

    public init(kind: Kind, id: UInt16, payload: Data = Data()) {
        self.kind = kind
        self.id = id
        self.payload = payload
    }

    public func encoded() throws -> Data {
        guard payload.count <= 65_533 else { throw ByteError.tooLarge }
        let length = UInt16(payload.count + 2)
        return Data([5, kind.rawValue, UInt8(truncatingIfNeeded: length), UInt8(length >> 8),
                     UInt8(truncatingIfNeeded: id), UInt8(id >> 8)]) + payload
    }

    public static func exact(_ bytes: Data) throws -> RaceFrame {
        let b = [UInt8](bytes)
        guard b.count >= 6, b[0] == 5, let kind = Kind(rawValue: b[1]) else { throw RaceError.malformed }
        let length = Int(b[2]) | Int(b[3]) << 8
        guard length >= 2, b.count == length + 4 else { throw RaceError.malformed }
        return RaceFrame(kind: kind, id: UInt16(b[4]) | UInt16(b[5]) << 8, payload: Data(b.dropFirst(6)))
    }
}

public enum RaceError: Error, Equatable { case malformed, overflow, partialExpired, nesting }

public struct RaceCodec: Sendable {
    public static let maximumFrameLength = 65_539
    private var buffer: [UInt8] = []
    private var partialSince: Duration?
    public var partialWindow: Duration
    public var bufferedByteCount: Int { buffer.count }

    public init(partialWindow: Duration = .seconds(5)) { self.partialWindow = partialWindow }

    /// Caller supplies monotonic time, so expiry can be tested without sleeping.
    public mutating func ingest(_ bytes: Data, at now: Duration) throws -> [RaceFrame] {
        try expire(at: now)
        guard buffer.count + bytes.count <= Self.maximumFrameLength * 2 else {
            reset()
            throw RaceError.overflow
        }
        buffer.append(contentsOf: bytes)
        var frames: [RaceFrame] = []
        var cursor = 0
        while cursor < buffer.count {
            let remaining = buffer.count - cursor
            guard buffer[cursor] == 5 else { cursor += 1; partialSince = nil; continue }
            if remaining >= 2 && RaceFrame.Kind(rawValue: buffer[cursor + 1]) == nil {
                cursor += 1; partialSince = nil; continue
            }
            guard remaining >= 4 else { break }
            let length = Int(buffer[cursor + 2]) | Int(buffer[cursor + 3]) << 8
            guard length >= 2 else { cursor += 1; partialSince = nil; continue }
            guard remaining >= length + 4 else { break }
            frames.append(try RaceFrame.exact(Data(buffer[cursor..<(cursor + length + 4)])))
            cursor += length + 4
            partialSince = nil
        }
        if cursor > 0 { buffer.removeFirst(cursor) }
        if buffer.isEmpty { partialSince = nil }
        else if partialSince == nil { partialSince = now }
        return frames
    }

    public mutating func expire(at now: Duration) throws {
        if let partialSince, now - partialSince >= partialWindow {
            reset()
            throw RaceError.partialExpired
        }
    }

    public mutating func reset() { buffer.removeAll(keepingCapacity: false); partialSince = nil }
}
