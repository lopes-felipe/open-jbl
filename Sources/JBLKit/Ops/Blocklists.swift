import Foundation

public enum Blocklists {
    public static func race(_ id: UInt16) -> Bool {
        (0x1C00...0x1C1B).contains(id) || (0x0400...0x04F0).contains(id) ||
        (0x0702...0x070F).contains(id) || (0x1E00...0x1E15).contains(id) ||
        Set<UInt16>([
            0x0A01, 0x0A03, 0x0A09, 0x0A0A, 0x0A0D, 0x020D,
            0x0E01, 0x0E02, 0x0E0A, 0x0E0B, 0x1101, 0x0CC0, 0x0CD5, 0x1680,
            0x0CD7, 0x2C86, 0x3101, 0x0057, 0x0067, 0x0007, 0x0011, 0x0083,
            0x0089, 0x0094, 0x0030
        ]).contains(id)
    }

    public static func aa(_ id: UInt8, payload: Data) -> Bool {
        if [0x95, 0x97, 0xF0, 0x15, 0x74, 0x61].contains(id) { return true }
        if [0xA3, 0xA4].contains(id), payload.first == 3 { return true }
        return id == 0x21 && payload.first == 0x37
    }

    public static func p4(command: UInt16, feature: UInt16, isSet: Bool, handshake: Bool) -> Bool {
        if [0x00FF, 0x0101, 0x0102, 0x0103, 0x0104, 0x02FF].contains(command) { return true }
        if feature == 0x1F00 { return true }
        if feature == 0x0007 && !handshake { return true }
        return isSet && Set<UInt16>([
            0x000F, 0x0011, 0x0BA4, 0x0BA5, 0x0032, 0x1F13,
            0x1E84, 0x003E, 0x004A, 0x004B, 0x0053, 0x0054
        ]).contains(feature)
    }
}
