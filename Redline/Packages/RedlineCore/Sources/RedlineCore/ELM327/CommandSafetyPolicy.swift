import Foundation

/// Redline V1 is a read-only tool. This policy is the single place that
/// decides which commands may reach the adapter from user-driven paths (the
/// developer console) and which commands are safe to repeat implicitly
/// (the ELM327 repeats the previous command when it receives a bare CR,
/// which the session's resync logic relies on).
///
/// Clearing DTCs (service 04) is deliberately NOT reachable from the
/// console; it will get its own explicit-confirmation flow in the
/// diagnostics phase.
public enum CommandSafetyPolicy {
    public enum Verdict: Sendable, Equatable {
        case allowed
        case blocked(String)
    }

    /// Read-only diagnostic services:
    /// 01 current data, 02 freeze frame, 03 stored DTCs, 06 on-board test
    /// results, 07 pending DTCs, 09 vehicle information, 0A permanent DTCs
    /// (SAE J1979), and 22 ReadDataByIdentifier (ISO 14229, read-only; for
    /// future verified manufacturer PIDs).
    public static let readOnlyServices: Set<UInt8> = [0x01, 0x02, 0x03, 0x06, 0x07, 0x09, 0x0A, 0x22]

    /// AT commands allowed from the console: informational queries only,
    /// matched exactly (command text after "AT", spaces removed).
    ///
    /// Formatting/addressing commands (E, L, S, H, CAF, SH, ...) are NOT
    /// allowed because they would silently change the response format the
    /// poller relies on mid-session; resets (Z, WS) would desynchronize the
    /// session. Never allowed: PP/SD (write adapter EEPROM), BRD/BRT (change
    /// the adapter's UART baud rate, which can break the BLE bridge), LP (low
    /// power), SP (sets *and saves* the protocol), MA/MR/MT (monitor modes
    /// that flood the link).
    static let consoleATCommands: Set<String> = ["I", "@1", "RV", "DP", "DPN", "CS", "IGN"]

    static let nonRepeatableATPrefixes: [String] = ["PP", "SD", "BRD", "BRT", "LP"]

    /// Normalized form: uppercased, whitespace removed.
    public static func normalize(_ command: String) -> String {
        command.uppercased().filter { !$0.isWhitespace }
    }

    /// The diagnostic service byte of an OBD request ("010C" → 0x01), or nil
    /// for AT commands / malformed input.
    public static func obdService(of command: String) -> UInt8? {
        let c = normalize(command)
        guard !c.hasPrefix("AT"), c.count >= 2 else { return nil }
        // An odd-length request may carry a trailing response-count digit.
        let body = c.count % 2 == 1 ? String(c.dropLast()) : c
        guard let bytes = Hex.bytes(body) else { return nil }
        return bytes.first
    }

    public static func evaluateConsoleCommand(_ command: String) -> Verdict {
        let c = normalize(command)
        guard !c.isEmpty else { return .blocked("Empty command") }
        if c.hasPrefix("AT") {
            let body = String(c.dropFirst(2))
            guard consoleATCommands.contains(body) else {
                return .blocked("AT\(body) is not on the console allowlist (informational AT commands only)")
            }
            return .allowed
        }
        guard let service = obdService(of: c) else {
            return .blocked("Not a valid hex OBD request")
        }
        guard readOnlyServices.contains(service) else {
            return .blocked(String(format: "Service %02X is not read-only; blocked in Redline V1", service))
        }
        return .allowed
    }

    /// Whether repeating `command` (via a bare CR) has no side effects.
    public static func isRepeatSafe(_ command: String) -> Bool {
        let c = normalize(command)
        if c.hasPrefix("AT") {
            let body = c.dropFirst(2)
            return !nonRepeatableATPrefixes.contains { body.hasPrefix($0) }
        }
        guard let service = obdService(of: c) else { return false }
        return readOnlyServices.contains(service)
    }
}
