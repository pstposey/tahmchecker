import Foundation

/// The physical adapters Redline supports, and how each one reaches iOS.
/// Adapter-specific behaviour lives at the transport boundary only: above
/// `OBDTransport`, both adapters run the same ELM327 session, initializer,
/// scheduler, decoders and UI.
public enum SupportedAdapter: String, Sendable, CaseIterable, Codable, Identifiable {
    /// BLE ELM327 adapter; GATT layout discovered and verified at runtime.
    case vgateICarPro2S
    /// MFi Bluetooth adapter reached through the External Accessory framework.
    case obdLinkMXPlus

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vgateICarPro2S: return "Vgate iCar Pro 2S"
        case .obdLinkMXPlus: return "OBDLink MX+"
        }
    }

    public var transport: TransportKind {
        switch self {
        case .vgateICarPro2S: return .bluetoothLE
        case .obdLinkMXPlus: return .externalAccessory
        }
    }
}

/// The adapter the user connected last, restored at launch.
public enum RememberedAdapter: Sendable, Equatable, Codable {
    /// A BLE peripheral (CoreBluetooth identifier) and the GATT pair that
    /// answered the ELM probe last time.
    case bluetoothLE(id: UUID, name: String, verifiedLink: GATTLinkCandidate?)
    /// An MFi accessory, identified by what iOS reports about it.
    case externalAccessory(RememberedAccessory)

    public var displayName: String {
        switch self {
        case .bluetoothLE(_, let name, _): return name
        case .externalAccessory(let a): return a.name.isEmpty ? "MFi accessory" : a.name
        }
    }

    public var transport: TransportKind {
        switch self {
        case .bluetoothLE: return .bluetoothLE
        case .externalAccessory: return .externalAccessory
        }
    }

    /// Settings saved before MX+ support stored only the BLE fields.
    public static func migrating(legacyID: UUID?, legacyName: String?, legacyLink: GATTLinkCandidate?) -> RememberedAdapter? {
        guard let legacyID else { return nil }
        return .bluetoothLE(id: legacyID, name: legacyName ?? "OBD adapter", verifiedLink: legacyLink)
    }
}

/// What Redline can tell about the connected adapter, and from what.
public struct AdapterIdentification: Sendable, Equatable {
    public var adapter: SupportedAdapter?
    /// The observations the conclusion rests on (names are hints, not proof).
    public var evidence: [String]

    public var summary: String {
        let what = adapter?.displayName ?? "not recognized"
        return evidence.isEmpty ? what : "\(what) (\(evidence.joined(separator: "; ")))"
    }
}

public enum AdapterIdentifier {
    /// Name-based identification. UNVERIFIED heuristics: the exact strings
    /// each adapter reports will be confirmed on hardware (HARDWARE_TEST.md);
    /// the debug report always shows the raw strings next to the conclusion.
    public static func identify(identity: TransportIdentity, linkDetails: TransportLinkDetails?,
                                adapterInfo: AdapterInfo?) -> AdapterIdentification {
        var evidence: [String] = []
        let accessoryText = (linkDetails?.items ?? [])
            .filter { ["Accessory name", "Manufacturer", "Model"].contains($0.key) }
            .map(\.value)
        let adapterText = [adapterInfo?.deviceDescription, adapterInfo?.identification, adapterInfo?.resetBanner]
            .compactMap { $0 }

        switch identity.kind {
        case .simulated:
            return AdapterIdentification(adapter: nil, evidence: ["simulator, no hardware"])
        case .externalAccessory:
            evidence.append("MFi accessory via External Accessory")
            let hay = (accessoryText + [identity.name] + adapterText).joined(separator: " ").lowercased()
            if hay.contains("obdlink") {
                evidence.append("name contains \"OBDLink\"")
                if hay.contains("mx+") || hay.contains("mx plus") {
                    evidence.append("model text contains \"MX+\"")
                    return AdapterIdentification(adapter: .obdLinkMXPlus, evidence: evidence)
                }
                evidence.append("OBDLink model not recognized")
                return AdapterIdentification(adapter: nil, evidence: evidence)
            }
            evidence.append("accessory name not recognized")
            return AdapterIdentification(adapter: nil, evidence: evidence)
        case .bluetoothLE:
            evidence.append("Bluetooth LE")
            let hay = ([identity.name] + adapterText).joined(separator: " ").lowercased()
            if ["vgate", "icar", "vlink", "v-link"].contains(where: { hay.contains($0) }) {
                evidence.append("name contains a Vgate/vLinker hint")
                return AdapterIdentification(adapter: .vgateICarPro2S, evidence: evidence)
            }
            evidence.append("name not recognized")
            return AdapterIdentification(adapter: nil, evidence: evidence)
        }
    }
}
