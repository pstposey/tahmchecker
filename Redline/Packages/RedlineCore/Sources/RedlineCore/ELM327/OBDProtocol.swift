import Foundation

/// OBD-II transport protocols as numbered by the ELM327 `AT SP` / `AT DPN`
/// commands. Numbering verified against python-OBD's ELM327 driver, which
/// follows the ELM327 datasheet.
public enum OBDProtocol: String, Sendable, CaseIterable, Codable {
    case automatic = "0"
    case sae_j1850_pwm = "1"
    case sae_j1850_vpw = "2"
    case iso_9141_2 = "3"
    case iso_14230_4_5baud = "4"
    case iso_14230_4_fast = "5"
    case iso_15765_4_can11_500 = "6"
    case iso_15765_4_can29_500 = "7"
    case iso_15765_4_can11_250 = "8"
    case iso_15765_4_can29_250 = "9"
    case sae_j1939 = "A"
    case user1_can = "B"
    case user2_can = "C"

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .sae_j1850_pwm: return "SAE J1850 PWM"
        case .sae_j1850_vpw: return "SAE J1850 VPW"
        case .iso_9141_2: return "ISO 9141-2"
        case .iso_14230_4_5baud: return "ISO 14230-4 KWP (5 baud init)"
        case .iso_14230_4_fast: return "ISO 14230-4 KWP (fast init)"
        case .iso_15765_4_can11_500: return "ISO 15765-4 CAN (11 bit, 500 kbaud)"
        case .iso_15765_4_can29_500: return "ISO 15765-4 CAN (29 bit, 500 kbaud)"
        case .iso_15765_4_can11_250: return "ISO 15765-4 CAN (11 bit, 250 kbaud)"
        case .iso_15765_4_can29_250: return "ISO 15765-4 CAN (29 bit, 250 kbaud)"
        case .sae_j1939: return "SAE J1939 CAN (29 bit, 250 kbaud)"
        case .user1_can: return "User1 CAN"
        case .user2_can: return "User2 CAN"
        }
    }

    /// CAN identifier width for ISO 15765-4 protocols, nil otherwise.
    public var canIDBits: Int? {
        switch self {
        case .iso_15765_4_can11_500, .iso_15765_4_can11_250, .user1_can, .user2_can: return 11
        case .iso_15765_4_can29_500, .iso_15765_4_can29_250, .sae_j1939: return 29
        default: return nil
        }
    }

    public var isCAN: Bool { canIDBits != nil }

    /// Parses an `AT DPN` reply: "6", or "A6" when the protocol was found by
    /// automatic search.
    public static func parseDPN(_ text: String) -> (proto: OBDProtocol, automatic: Bool)? {
        var t = text.trimmingCharacters(in: .whitespaces).uppercased()
        var automatic = false
        if t.count == 2, t.hasPrefix("A") {
            automatic = true
            t.removeFirst()
        }
        guard t.count == 1, let p = OBDProtocol(rawValue: t) else { return nil }
        return (p, automatic)
    }
}
