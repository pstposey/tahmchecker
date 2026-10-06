/// Platform-neutral description of a discovered GATT characteristic.
public struct GATTCharacteristicInfo: Sendable, Hashable, Codable {
    public struct Properties: OptionSet, Sendable, Hashable, Codable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let read = Properties(rawValue: 1 << 0)
        public static let write = Properties(rawValue: 1 << 1)
        public static let writeWithoutResponse = Properties(rawValue: 1 << 2)
        public static let notify = Properties(rawValue: 1 << 3)
        public static let indicate = Properties(rawValue: 1 << 4)

        public var canWrite: Bool { !isDisjoint(with: [.write, .writeWithoutResponse]) }
        public var canSubscribe: Bool { !isDisjoint(with: [.notify, .indicate]) }

        public var shortDescription: String {
            var parts: [String] = []
            if contains(.read) { parts.append("read") }
            if contains(.write) { parts.append("write") }
            if contains(.writeWithoutResponse) { parts.append("writeNoRsp") }
            if contains(.notify) { parts.append("notify") }
            if contains(.indicate) { parts.append("indicate") }
            return parts.joined(separator: ",")
        }
    }

    /// Uppercased UUID string as reported by the platform ("FFF0" or 128-bit).
    public var serviceUUID: String
    public var uuid: String
    public var properties: Properties

    public init(serviceUUID: String, uuid: String, properties: Properties) {
        self.serviceUUID = serviceUUID.uppercased()
        self.uuid = uuid.uppercased()
        self.properties = properties
    }
}

public enum GATTWriteType: String, Sendable, Codable {
    case withoutResponse
    case withResponse
}

/// A (write, notify) characteristic pair that might carry the ELM327 stream.
/// A candidate is only trusted after an ELM probe succeeds over it.
public struct GATTLinkCandidate: Sendable, Hashable, Codable {
    public var serviceUUID: String
    public var writeUUID: String
    public var notifyUUID: String
    public var writeType: GATTWriteType
    public var score: Int

    public init(serviceUUID: String, writeUUID: String, notifyUUID: String, writeType: GATTWriteType, score: Int = 0) {
        self.serviceUUID = serviceUUID.uppercased()
        self.writeUUID = writeUUID.uppercased()
        self.notifyUUID = notifyUUID.uppercased()
        self.writeType = writeType
        self.score = score
    }

    /// Identity ignoring the score.
    public func matches(_ other: GATTLinkCandidate) -> Bool {
        serviceUUID == other.serviceUUID && writeUUID == other.writeUUID && notifyUUID == other.notifyUUID
    }

    public var summary: String {
        "service \(serviceUUID) write \(writeUUID) (\(writeType.rawValue)) notify \(notifyUUID)"
    }
}

/// Orders GATT characteristic pairs by how likely they are to be the ELM327
/// serial bridge, so the probe tries the most plausible pair first.
///
/// IMPORTANT: nothing here is treated as truth. The Vgate iCar Pro 2S GATT
/// layout is UNVERIFIED (no authoritative documentation was found). Ranking
/// only decides probe order; a pair is accepted only when an `ATI` probe over
/// it returns an ELM-style response terminated by the `>` prompt.
public enum GATTCandidateRanker {
    /// Bluetooth SIG-assigned services that never carry a vendor serial
    /// stream (Generic Access, Generic Attribute, Device Information,
    /// Battery, Current Time). These are excluded from probing.
    public static let standardServices: Set<String> = ["1800", "1801", "180A", "180F", "1805"]

    /// Layouts reported by community sources for generic BLE ELM327 clones.
    /// UNVERIFIED for the Vgate iCar Pro 2S — used only as a tie-breaker.
    public static let unverifiedCommunityHints: [(service: String, write: String, notify: String)] = [
        ("FFF0", "FFF2", "FFF1"),
        ("FFE0", "FFE1", "FFE1"),
        ("18F0", "2AF1", "2AF0"),
    ]

    /// Maximum number of pairs the probe will try. Probing writes a harmless
    /// `ATI\r` to each candidate; bounding attempts limits writes to
    /// characteristics whose purpose we don't know.
    public static let maxProbeAttempts = 4

    public static func candidates(
        from characteristics: [GATTCharacteristicInfo],
        preferred: GATTLinkCandidate? = nil
    ) -> [GATTLinkCandidate] {
        let eligible = characteristics.filter { !standardServices.contains($0.serviceUUID) }
        let writers = eligible.filter { $0.properties.canWrite }
        let notifiers = eligible.filter { $0.properties.canSubscribe }

        var result: [GATTLinkCandidate] = []
        for w in writers {
            for n in notifiers where n.serviceUUID == w.serviceUUID {
                let writeType: GATTWriteType = w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                var candidate = GATTLinkCandidate(
                    serviceUUID: w.serviceUUID, writeUUID: w.uuid, notifyUUID: n.uuid, writeType: writeType
                )
                var score = 100 // same vendor service
                if n.properties.contains(.notify) { score += 10 }
                if writeType == .withoutResponse { score += 5 }
                if unverifiedCommunityHints.contains(where: {
                    $0.service == w.serviceUUID && $0.write == w.uuid && $0.notify == n.uuid
                }) {
                    score += 50
                }
                if let preferred, preferred.matches(candidate) { score += 1_000 }
                candidate.score = score
                result.append(candidate)
            }
        }
        // Deterministic order: score, then UUID text.
        return result.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return ($0.serviceUUID, $0.writeUUID, $0.notifyUUID) < ($1.serviceUUID, $1.writeUUID, $1.notifyUUID)
        }
    }
}
