/// Strict hexadecimal helpers. Stricter than `UInt8(_:radix:)`, which also
/// accepts a leading "+" or "-".
public enum Hex {
    public static func isHexDigit(_ c: Character) -> Bool {
        guard let ascii = c.asciiValue else { return false }
        return isHexDigit(ascii)
    }

    public static func isHexDigit(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
    }

    /// Parses an even-length run of hex digits with no separators ("410C1AF8").
    public static func bytes(_ text: some StringProtocol) -> [UInt8]? {
        let ascii = Array(text.utf8)
        guard !ascii.isEmpty, ascii.count % 2 == 0, ascii.allSatisfy(isHexDigit) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(ascii.count / 2)
        var i = 0
        while i < ascii.count {
            out.append(nibble(ascii[i]) << 4 | nibble(ascii[i + 1]))
            i += 2
        }
        return out
    }

    /// Parses an unsigned value from 1...8 hex digits ("7E8", "18DAF110").
    public static func value(_ text: some StringProtocol) -> UInt32? {
        let ascii = Array(text.utf8)
        guard !ascii.isEmpty, ascii.count <= 8, ascii.allSatisfy(isHexDigit) else { return nil }
        return ascii.reduce(UInt32(0)) { $0 << 4 | UInt32(nibble($1)) }
    }

    public static func string(_ bytes: some Sequence<UInt8>, separator: String = " ") -> String {
        bytes.map { byteString($0) }.joined(separator: separator)
    }

    public static func byteString(_ b: UInt8) -> String {
        let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]
        return String([digits[Int(b >> 4)], digits[Int(b & 0x0F)]])
    }

    private static func nibble(_ ascii: UInt8) -> UInt8 {
        switch ascii {
        case 0x30...0x39: return ascii - 0x30
        case 0x41...0x46: return ascii - 0x41 + 10
        default: return ascii - 0x61 + 10
        }
    }
}
