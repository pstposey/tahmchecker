import Foundation

/// The node that sent a response: an 11-bit CAN ID (0x7E8), a 29-bit CAN ID
/// (0x18DAF110), or a legacy-protocol source address byte.
public struct ECUAddress: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {
    public enum Kind: String, Sendable, Codable {
        case can11
        case can29
        case legacy
    }

    public let value: UInt32
    public let kind: Kind

    public init(value: UInt32, kind: Kind) {
        self.value = value
        self.kind = kind
    }

    public static func can11(_ id: UInt32) -> ECUAddress { ECUAddress(value: id, kind: .can11) }

    public var description: String {
        switch kind {
        case .can11: return String(format: "%03X", value)
        case .can29: return String(format: "%08X", value)
        case .legacy: return String(format: "%02X", value)
        }
    }

    /// ISO 15765-4 legislated 11-bit IDs: ECUs respond on 0x7E8–0x7EF to
    /// physical requests sent on (response ID − 8). Returns the physical
    /// request ID for that ECU, if this address is one of those.
    public var physicalRequestID: UInt32? {
        guard kind == .can11, (0x7E8...0x7EF).contains(value) else { return nil }
        return value - 8
    }

    public static func < (lhs: ECUAddress, rhs: ECUAddress) -> Bool {
        (lhs.kind.rawValue, lhs.value) < (rhs.kind.rawValue, rhs.value)
    }
}

/// A complete diagnostic message from one ECU: e.g. `41 0C 1A F8`.
/// For CAN this is the ISO-TP payload with PCI bytes removed.
public struct ECUMessage: Sendable, Equatable {
    /// nil when headers were off (the responder is unknown).
    public let ecu: ECUAddress?
    public let payload: [UInt8]

    public init(ecu: ECUAddress?, payload: [UInt8]) {
        self.ecu = ecu
        self.payload = payload
    }
}

public struct ParsedOBDResponse: Sendable, Equatable {
    public var messages: [ECUMessage] = []
    /// Lines or frames that could not be interpreted. Logged, never fatal.
    public var issues: [String] = []
}

/// Converts the hex lines of an ELM327 response into per-ECU messages.
///
/// Supported display formats (ELM327 with CAN auto-formatting on, ATCAF1):
///
/// Headers ON (ATH1), CAN 11-bit, spaces on — Redline's default:
///     7E8 04 41 0C 1A F8
///     7E8 10 14 49 02 01 31 47 31        (ISO-TP first frame)
///     7E8 21 4A 43 35 34 34 34 52        (consecutive frame)
///   The byte after the ID is the ISO-TP PCI byte; bytes beyond the length it
///   declares are padding and are ignored (behaviour corroborated by
///   python-OBD's CAN parser).
///
/// Headers ON, CAN 29-bit: the ID is shown as four bytes
///     18 DA F1 10 03 41 0D 00
///
/// Headers ON, legacy protocols (J1850/ISO 9141/KWP): 3 header bytes, data,
/// then a checksum byte. UNTESTED on hardware — the target vehicle is CAN.
///
/// Headers OFF: data only. Multi-frame messages appear as a byte count line
/// followed by indexed lines:
///     014
///     0: 49 02 01 31 47 31
///     1: 4A 43 35 34 34 34 52
public enum OBDFrameParser {
    public static func parse(lines: [String], headersOn: Bool, protocol proto: OBDProtocol?) -> ParsedOBDResponse {
        headersOn ? parseWithHeaders(lines, proto: proto) : parseWithoutHeaders(lines)
    }

    // MARK: Headers on

    struct Frame {
        let ecu: ECUAddress
        let bytes: [UInt8]
    }

    static func parseWithHeaders(_ lines: [String], proto: OBDProtocol?) -> ParsedOBDResponse {
        var result = ParsedOBDResponse()
        var canFrames: [Frame] = []

        for line in lines {
            switch splitHeaderLine(line, proto: proto) {
            case .can(let frame):
                canFrames.append(frame)
            case .legacy(let ecu, let data):
                result.messages.append(ECUMessage(ecu: ecu, payload: data))
            case .invalid(let why):
                result.issues.append("\(why): \(line)")
            }
        }

        let assembled = assembleISOTP(canFrames)
        result.messages.append(contentsOf: assembled.messages)
        result.issues.append(contentsOf: assembled.issues)
        return result
    }

    enum HeaderLine {
        case can(Frame)
        case legacy(ECUAddress, [UInt8])
        case invalid(String)
    }

    static func splitHeaderLine(_ line: String, proto: OBDProtocol?) -> HeaderLine {
        let tokens = line.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return .invalid("empty line") }

        // Spaces off: one contiguous token. Split by known protocol.
        if tokens.count == 1 {
            let t = tokens[0]
            let bits = proto?.canIDBits ?? (t.count % 2 == 1 ? 11 : nil)
            switch bits {
            case 11:
                guard t.count > 3, let id = Hex.value(t.prefix(3)), let bytes = Hex.bytes(t.dropFirst(3)) else {
                    return .invalid("malformed 11-bit frame")
                }
                return .can(Frame(ecu: .can11(id), bytes: bytes))
            case 29:
                guard t.count > 8, let id = Hex.value(t.prefix(8)), let bytes = Hex.bytes(t.dropFirst(8)) else {
                    return .invalid("malformed 29-bit frame")
                }
                return .can(Frame(ecu: ECUAddress(value: id, kind: .can29), bytes: bytes))
            default:
                guard let bytes = Hex.bytes(t) else { return .invalid("malformed frame") }
                return legacyFrame(bytes)
            }
        }

        // Spaces on, 11-bit CAN: 3-digit ID token.
        if tokens[0].count == 3 {
            guard let id = Hex.value(tokens[0]) else { return .invalid("bad CAN ID") }
            guard let bytes = byteTokens(tokens.dropFirst()) else { return .invalid("bad data byte") }
            return .can(Frame(ecu: .can11(id), bytes: bytes))
        }

        guard let all = byteTokens(tokens[...]) else { return .invalid("bad data byte") }

        let looksLike29 = all.count >= 5 && all[0] == 0x18 && (all[1] == 0xDA || all[1] == 0xDB)
        if proto?.canIDBits == 29 || (proto == nil && looksLike29) {
            guard all.count >= 5 else { return .invalid("short 29-bit frame") }
            let id = all[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return .can(Frame(ecu: ECUAddress(value: id, kind: .can29), bytes: Array(all[4...])))
        }
        if proto?.canIDBits == 11 {
            return .invalid("expected 11-bit CAN ID")
        }
        return legacyFrame(all)
    }

    static func legacyFrame(_ bytes: [UInt8]) -> HeaderLine {
        // [priority, target, source, data..., checksum]
        guard bytes.count >= 5 else { return .invalid("short legacy frame") }
        let ecu = ECUAddress(value: UInt32(bytes[2]), kind: .legacy)
        return .legacy(ecu, Array(bytes[3..<(bytes.count - 1)]))
    }

    static func byteTokens(_ tokens: ArraySlice<String>) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(tokens.count)
        for t in tokens {
            guard t.count == 2, let b = Hex.bytes(t) else { return nil }
            out.append(b[0])
        }
        return out
    }

    /// ISO 15765-2 reassembly. Frames from different ECUs may interleave.
    static func assembleISOTP(_ frames: [Frame]) -> ParsedOBDResponse {
        struct Partial {
            var expected: Int
            var data: [UInt8]
            var nextSequence: UInt8
        }
        var result = ParsedOBDResponse()
        var partial: [ECUAddress: Partial] = [:]

        for frame in frames {
            guard let pci = frame.bytes.first else {
                result.issues.append("\(frame.ecu): empty frame")
                continue
            }
            switch pci >> 4 {
            case 0x0: // single frame
                let length = Int(pci & 0x0F)
                guard length > 0, frame.bytes.count >= 1 + length else {
                    result.issues.append("\(frame.ecu): single frame length \(length) but \(frame.bytes.count - 1) data bytes")
                    continue
                }
                result.messages.append(ECUMessage(ecu: frame.ecu, payload: Array(frame.bytes[1...length])))
            case 0x1: // first frame
                guard frame.bytes.count >= 2 else {
                    result.issues.append("\(frame.ecu): truncated first frame")
                    continue
                }
                if partial[frame.ecu] != nil {
                    result.issues.append("\(frame.ecu): new first frame before previous message completed")
                }
                let length = Int(pci & 0x0F) << 8 | Int(frame.bytes[1])
                let data = Array(frame.bytes.dropFirst(2))
                if data.count >= length {
                    result.messages.append(ECUMessage(ecu: frame.ecu, payload: Array(data.prefix(length))))
                    partial[frame.ecu] = nil
                } else {
                    partial[frame.ecu] = Partial(expected: length, data: data, nextSequence: 1)
                }
            case 0x2: // consecutive frame
                guard var p = partial[frame.ecu] else {
                    result.issues.append("\(frame.ecu): consecutive frame without first frame")
                    continue
                }
                let sequence = pci & 0x0F
                guard sequence == p.nextSequence else {
                    result.issues.append("\(frame.ecu): sequence \(sequence), expected \(p.nextSequence); message dropped")
                    partial[frame.ecu] = nil
                    continue
                }
                p.data.append(contentsOf: frame.bytes.dropFirst())
                p.nextSequence = (sequence + 1) & 0x0F
                if p.data.count >= p.expected {
                    result.messages.append(ECUMessage(ecu: frame.ecu, payload: Array(p.data.prefix(p.expected))))
                    partial[frame.ecu] = nil
                } else {
                    partial[frame.ecu] = p
                }
            case 0x3: // flow control (normally only sent by the tester)
                continue
            default:
                result.issues.append("\(frame.ecu): unknown PCI type \(Hex.byteString(pci))")
            }
        }
        for (ecu, p) in partial.sorted(by: { $0.key < $1.key }) {
            result.issues.append("\(ecu): incomplete multi-frame message (\(p.data.count)/\(p.expected) bytes)")
        }
        return result
    }

    // MARK: Headers off

    static func parseWithoutHeaders(_ lines: [String]) -> ParsedOBDResponse {
        var result = ParsedOBDResponse()
        var multiLength: Int?
        var multiData: [UInt8] = []

        func flushMulti() {
            if let length = multiLength {
                if multiData.count >= length {
                    result.messages.append(ECUMessage(ecu: nil, payload: Array(multiData.prefix(length))))
                } else {
                    result.issues.append("incomplete multi-line message (\(multiData.count)/\(length) bytes)")
                }
            }
            multiLength = nil
            multiData = []
        }

        for line in lines {
            let compact = line.replacingOccurrences(of: " ", with: "")
            // Byte-count line ("014") that precedes indexed lines.
            if compact.count == 3, let n = Hex.value(compact) {
                flushMulti()
                multiLength = Int(n)
                continue
            }
            if let colon = line.firstIndex(of: ":") {
                guard let bytes = Hex.bytes(line[line.index(after: colon)...].replacingOccurrences(of: " ", with: "")) else {
                    result.issues.append("bad indexed line: \(line)")
                    continue
                }
                if multiLength == nil { multiLength = Int.max } // tolerate a missing count line
                multiData.append(contentsOf: bytes)
                continue
            }
            if multiLength == Int.max {
                // Indexed run without a count line ends here.
                result.messages.append(ECUMessage(ecu: nil, payload: multiData))
                multiLength = nil
                multiData = []
            } else {
                flushMulti()
            }
            guard let bytes = Hex.bytes(compact) else {
                result.issues.append("bad data line: \(line)")
                continue
            }
            result.messages.append(ECUMessage(ecu: nil, payload: bytes))
        }
        if multiLength == Int.max {
            result.messages.append(ECUMessage(ecu: nil, payload: multiData))
        } else {
            flushMulti()
        }
        return result
    }
}
