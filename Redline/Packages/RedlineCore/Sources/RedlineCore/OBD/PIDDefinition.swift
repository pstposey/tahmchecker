import Foundation

/// Declarative decoding formula for an OBD data field.
///
/// SAE J1979 expresses standard PIDs as linear functions of big-endian
/// unsigned byte groups (A, B, ...), e.g. RPM = (256A + B) / 4. Representing
/// them as data keeps decoding in one audited function instead of a
/// per-PID switch, and lets the simulator encode values with the exact
/// inverse.
public enum PIDFormula: Sendable, Equatable {
    /// value = UInt(data[byteOffset ..< byteOffset + byteCount]) × scale + offset
    case linear(byteOffset: Int, byteCount: Int, scale: Double, offset: Double)

    /// Single byte A: A × scale + offset.
    public static func a(scale: Double = 1, offset: Double = 0) -> PIDFormula {
        .linear(byteOffset: 0, byteCount: 1, scale: scale, offset: offset)
    }

    /// Two bytes A,B: (256A + B) × scale + offset.
    public static func ab(scale: Double = 1, offset: Double = 0) -> PIDFormula {
        .linear(byteOffset: 0, byteCount: 2, scale: scale, offset: offset)
    }

    public var requiredBytes: Int {
        switch self {
        case .linear(let o, let n, _, _): return o + n
        }
    }

    /// nil when `data` is too short.
    public func evaluate(_ data: [UInt8]) -> Double? {
        switch self {
        case .linear(let o, let n, let scale, let offset):
            guard n > 0, n <= 4, data.count >= o + n else { return nil }
            let raw = data[o..<(o + n)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return Double(raw) * scale + offset
        }
    }

    /// Inverse of `evaluate` (rounded, clamped to the encodable range),
    /// producing `totalBytes` bytes. Used only by the simulator.
    public func encode(_ value: Double, totalBytes: Int) -> [UInt8] {
        switch self {
        case .linear(let o, let n, let scale, let offset):
            var out = [UInt8](repeating: 0, count: max(totalBytes, o + n))
            let maxRaw = Double((UInt64(1) << (8 * UInt64(n))) - 1)
            let raw = UInt64(min(max(((value - offset) / scale).rounded(), 0), maxRaw))
            for i in 0..<n {
                out[o + i] = UInt8((raw >> (8 * UInt64(n - 1 - i))) & 0xFF)
            }
            return out
        }
    }

    /// Human-readable formula for docs/debug ("(256A+B) × 0.25").
    public var formulaDescription: String {
        switch self {
        case .linear(let o, let n, let scale, let offset):
            let letters = Array("ABCDEFGH")
            let vars = (o..<(o + n)).map { String(letters[$0]) }
            let raw = n == 1 ? vars[0] : "UInt(\(vars.joined()))"
            var s = raw
            if scale != 1 { s += " × \(Self.trim(scale))" }
            if offset > 0 { s += " + \(Self.trim(offset))" }
            if offset < 0 { s += " − \(Self.trim(-offset))" }
            return s
        }
    }

    private static func trim(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.8g", v)
    }
}

/// (service, PID) pair.
public struct PIDKey: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {
    public let mode: UInt8
    public let pid: UInt8

    public init(mode: UInt8, pid: UInt8) {
        self.mode = mode
        self.pid = pid
    }

    /// ELM327 request text, e.g. "010C".
    public var requestCommand: String { Hex.byteString(mode) + Hex.byteString(pid) }
    public var description: String { requestCommand }

    public static func < (a: PIDKey, b: PIDKey) -> Bool { (a.mode, a.pid) < (b.mode, b.pid) }
}

/// A requestable OBD parameter: where it lives and how to decode it.
public struct PIDDefinition: Sendable, Equatable, Identifiable {
    public let key: PIDKey
    /// Data bytes following the echoed service+PID in a positive response.
    public let responseLength: Int
    public let formula: PIDFormula
    public let channel: ChannelDescriptor
    /// Where the definition comes from (standard section, or evidence for
    /// manufacturer-specific PIDs).
    public let reference: String

    public var id: ChannelID { channel.id }
    public var mode: UInt8 { key.mode }
    public var pid: UInt8 { key.pid }

    public init(mode: UInt8, pid: UInt8, responseLength: Int, formula: PIDFormula, channel: ChannelDescriptor, reference: String) {
        precondition(formula.requiredBytes <= responseLength, "formula reads beyond the response")
        self.key = PIDKey(mode: mode, pid: pid)
        self.responseLength = responseLength
        self.formula = formula
        self.channel = channel
        self.reference = reference
    }
}
