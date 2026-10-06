import Foundation

/// Redline Milestone 1 is strictly read-only toward the vehicle. This policy
/// is the single authority on what may be transmitted to the adapter, and
/// `ELM327Session.execute` enforces it on EVERY command from EVERY caller
/// (initializer, poller, developer console). A refused command is never
/// written. See docs/SAFETY.md for the full outbound inventory.
///
/// Design: allowlists only. Anything not explicitly listed is refused —
/// including every write/control service (clear DTCs, ECU reset, actuator
/// control, SecurityAccess, RoutineControl, WriteDataByIdentifier, memory
/// writes, download/upload/flash, CommunicationControl) and every ELM327
/// command that could send arbitrary CAN frames, change the adapter's
/// persistent configuration (beyond `AT SP 0`, see below) or flood the link.
public enum CommandSafetyPolicy {
    public enum Verdict: Sendable, Equatable {
        case allowed
        case blocked(String)

        public var isAllowed: Bool { self == .allowed }
    }

    /// SAE J1979 / ISO 15031-5 services that only READ data:
    /// 01 current data, 02 freeze-frame data, 03 stored DTCs, 06 on-board
    /// monitoring test results, 07 pending DTCs, 09 vehicle information,
    /// 0A permanent DTCs.
    ///
    /// Deliberately excluded: 04 (clears DTCs, freeze frame and readiness
    /// monitors), 05 (non-CAN O2 monitoring; unneeded), 08 (request control of
    /// an on-board system/test/component — actuator control), and every
    /// ISO 14229 (UDS) service, including the read-only 0x22, which no
    /// Milestone 1 feature needs (manufacturer PIDs come later, only once
    /// verified).
    public static let readOnlyServices: Set<UInt8> = [0x01, 0x02, 0x03, 0x06, 0x07, 0x09, 0x0A]

    /// A request must fit one ISO 15765-2 CAN single frame (≤ 7 data bytes),
    /// so the adapter never segments an outbound message.
    public static let maxRequestBytes = 7

    /// ELM327 commands Redline itself sends (text after "AT"). All configure
    /// only the adapter/session; none is transmitted onto the vehicle bus.
    /// Volatile (lost on reset/power-off) unless noted:
    /// - Z: reset the adapter to its defaults (volatile).
    /// - E0, L0, S1, H1: echo off, linefeeds off, spaces on, headers on (formatting).
    /// - SP0: select automatic protocol search. AT SP also STORES the protocol
    ///   as the adapter's default — the only persistent adapter write. Redline
    ///   sends it only when the adapter is not already set to automatic.
    /// - I, @1, RV, DP, DPN: read adapter identification, description, supply
    ///   voltage, protocol name and number.
    static let initializationATCommands: Set<String> = ["Z", "E0", "L0", "S1", "H1", "SP0", "I", "@1", "RV", "DP", "DPN"]

    /// AT SH with a legislated ISO 15765-4 physical request ID (0x7E0–0x7E7).
    /// Only selects which ECU receives the (still read-only) requests; volatile.
    static let headerATCommands: Set<String> = Set((0x7E0...0x7E7).map { "SH" + String($0, radix: 16, uppercase: true) })

    /// AT commands that only read: identification, description, supply
    /// voltage, protocol name/number, CAN error counters (CS) and the
    /// ignition input (IGN). They change nothing, so repeating them is harmless.
    static let informationalATCommands: Set<String> = ["I", "@1", "RV", "DP", "DPN", "CS", "IGN"]

    /// Allowed from the developer console: informational queries only.
    /// Formatting, addressing and reset commands would change what the poller
    /// relies on mid-session, so they are excluded even though harmless to
    /// the vehicle.
    public static let consoleATCommands: Set<String> = informationalATCommands

    static var transmittableATCommands: Set<String> {
        initializationATCommands.union(headerATCommands).union(consoleATCommands)
    }

    /// Uppercased with all whitespace removed. This is also the exact text
    /// the session transmits, so what is evaluated is what is sent.
    public static func normalize(_ command: String) -> String {
        command.uppercased().filter { !$0.isWhitespace }
    }

    /// Characters the ELM327 command line may contain. Anything else —
    /// control characters such as CR/LF that would split one string into two
    /// adapter commands, NUL, non-ASCII look-alikes — is refused outright.
    static func isPlainCommandText(_ normalized: String) -> Bool {
        !normalized.isEmpty && normalized.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || b == 0x40 // 0-9 A-Z @
        }
    }

    /// Parsed OBD request: service byte, total data bytes, response-count digit.
    struct OBDRequest: Equatable {
        let service: UInt8
        let byteCount: Int
        let responseCount: Character?
    }

    /// Parses "010C", "010C0B11", "010C1" (ELM327 response-count suffix).
    static func parseOBDRequest(_ normalized: String) -> OBDRequest? {
        guard !normalized.hasPrefix("AT"), normalized.count >= 2 else { return nil }
        var body = normalized
        var count: Character?
        if body.count % 2 == 1 {
            count = body.removeLast()
            // The suffix is one hex digit 1–F; "0" is meaningless.
            guard let c = count, Hex.isHexDigit(c), c != "0" else { return nil }
        }
        guard let bytes = Hex.bytes(body), let service = bytes.first else { return nil }
        return OBDRequest(service: service, byteCount: bytes.count, responseCount: count)
    }

    /// The diagnostic service byte of an OBD request ("010C" → 0x01).
    public static func obdService(of command: String) -> UInt8? {
        parseOBDRequest(normalize(command))?.service
    }

    /// The session-level gate applied to every outbound command.
    public static func evaluateTransmission(_ command: String) -> Verdict {
        evaluate(command, allowedAT: transmittableATCommands)
    }

    /// The (stricter) gate for text typed into the developer console.
    public static func evaluateConsoleCommand(_ command: String) -> Verdict {
        evaluate(command, allowedAT: consoleATCommands)
    }

    private static func evaluate(_ command: String, allowedAT: Set<String>) -> Verdict {
        // The adapter ends a command at CR (and some clones at LF). A line
        // break inside one command string can only be a bug or an injection
        // attempt, so it is refused rather than silently stripped.
        if command.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) {
            return .blocked("Contains a line break (the adapter would treat it as a command separator)")
        }
        let c = normalize(command)
        guard !c.isEmpty else { return .blocked("Empty command") }
        guard isPlainCommandText(c) else {
            return .blocked("Contains characters outside 0-9, A-Z and @ (control characters could split it into several adapter commands)")
        }
        if c.hasPrefix("AT") {
            let body = String(c.dropFirst(2))
            guard allowedAT.contains(body) else {
                return .blocked("AT\(body) is not an allowed adapter command (read-only policy)")
            }
            return .allowed
        }
        guard let request = parseOBDRequest(c) else {
            return .blocked("Not a valid hex OBD request")
        }
        guard readOnlyServices.contains(request.service) else {
            return .blocked(String(format: "Service %02X is not a read-only service; blocked in Redline Milestone 1", request.service))
        }
        guard request.byteCount <= maxRequestBytes else {
            return .blocked("Request longer than \(maxRequestBytes) bytes (one CAN frame)")
        }
        return .allowed
    }

    /// Whether the adapter repeating `command` (it repeats the previous
    /// command when it receives a bare CR) has no side effects. Only reads
    /// qualify: allowed OBD requests and informational AT queries. Every
    /// other AT command is refused even though it is transmittable — a
    /// repeated `AT SP 0` would rewrite the adapter's stored protocol, and a
    /// repeated `AT Z` or formatting command would reset session state.
    public static func isRepeatSafe(_ command: String) -> Bool {
        guard evaluateTransmission(command).isAllowed else { return false }
        let c = normalize(command)
        if c.hasPrefix("AT") {
            return informationalATCommands.contains(String(c.dropFirst(2)))
        }
        return true // a read-only OBD request (the gate admitted it)
    }
}
