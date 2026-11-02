import Foundation

public enum ByteError: Error, Equatable { case invalidHex, truncated, tooLarge }

public extension Data {
    init(hex: String) throws {
        let compact = hex.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
        guard compact.count.isMultiple(of: 2), compact.allSatisfy(\.isHexDigit) else {
            throw ByteError.invalidHex
        }
        var result = Data()
        var index = compact.startIndex
        while index != compact.endIndex {
            let end = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<end], radix: 16) else { throw ByteError.invalidHex }
            result.append(byte)
            index = end
        }
        self = result
    }

    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

public enum CRC16 {
    public static func modbusZero(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }

    public static func host(_ name: String) -> UInt16 { modbusZero(name.utf8.prefix(50)) }
}
