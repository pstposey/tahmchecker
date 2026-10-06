/// Which service 01 PIDs each ECU reports as supported.
///
/// Discovery uses the standard "PIDs supported" requests (01 00, 01 20,
/// 01 40, …). Each returns a 32-bit bitmask: the most significant bit of
/// byte A is PID base+1, the least significant bit of byte D is PID
/// base+0x20, which also signals that the next range can be queried.
public struct PIDSupportMap: Sendable, Equatable {
    /// Responder used when headers are off and the ECU is unknown.
    public static let unknownECU = ECUAddress(value: 0xFFFF_FFFF, kind: .legacy)

    public private(set) var byECU: [ECUAddress: Set<UInt8>] = [:]
    /// Ranges (00, 20, 40, …) that have been queried.
    public private(set) var queriedRanges: Set<UInt8> = []

    public init() {}

    public static func decodeBitmask(base: UInt8, data: [UInt8]) -> Set<UInt8> {
        var result: Set<UInt8> = []
        guard data.count >= 4 else { return result }
        for i in 0..<32 where data[i / 8] & (0x80 >> UInt8(i % 8)) != 0 {
            let pid = Int(base) + i + 1
            if pid <= 0xFF { result.insert(UInt8(pid)) }
        }
        return result
    }

    public mutating func record(base: UInt8, bitmask: [UInt8], from ecu: ECUAddress?) {
        let key = ecu ?? Self.unknownECU
        byECU[key, default: []].formUnion(Self.decodeBitmask(base: base, data: bitmask))
        queriedRanges.insert(base)
    }

    public mutating func markQueried(base: UInt8) {
        queriedRanges.insert(base)
    }

    public var allSupported: Set<UInt8> { byECU.values.reduce(into: []) { $0.formUnion($1) } }

    public func isSupported(_ pid: UInt8) -> Bool { byECU.values.contains { $0.contains(pid) } }

    public var respondingECUs: [ECUAddress] { byECU.keys.sorted() }

    /// ECUs that support `pid`, best first: 0x7E8 (by ISO 15765-4 convention
    /// the first OBD ECU, normally the engine controller), then by address.
    public func ecus(supporting pid: UInt8) -> [ECUAddress] {
        byECU.filter { $0.value.contains(pid) }.keys.sorted { a, b in
            if a == .can11(0x7E8) { return true }
            if b == .can11(0x7E8) { return false }
            return a < b
        }
    }

    /// The next range to query after the ones already queried, if any ECU
    /// advertised it (bit base+0x20 set). Returns nil when discovery is done.
    public func nextRangeToQuery() -> UInt8? {
        var base: UInt8 = 0x00
        while true {
            if !queriedRanges.contains(base) { return base == 0x00 || isSupported(base) ? base : nil }
            guard base <= 0xC0 else { return nil }
            let next = base + 0x20
            guard isSupported(next) else { return nil }
            base = next
        }
    }
}
