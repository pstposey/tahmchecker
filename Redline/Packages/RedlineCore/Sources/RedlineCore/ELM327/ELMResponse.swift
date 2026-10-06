import Foundation

/// Status and error messages an ELM327 can print instead of (or alongside)
/// data. Source: ELM327 datasheet "Messages and Responses" section, as
/// mirrored by python-OBD and the Linux can327 documentation.
public enum ELMMessage: String, Sendable, CaseIterable, Equatable {
    case noData = "NO DATA"
    case unableToConnect = "UNABLE TO CONNECT"
    case canError = "CAN ERROR"
    case busBusy = "BUS BUSY"
    case busError = "BUS ERROR"
    case busInitError = "BUS INIT ERROR"
    case bufferFull = "BUFFER FULL"
    case dataError = "DATA ERROR"
    case rxError = "RX ERROR"
    case feedbackError = "FB ERROR"
    case lowVoltageReset = "LV RESET"
    case stopped = "STOPPED"
    case activityAlert = "ACT ALERT"
    case lowPowerAlert = "LP ALERT"
    /// "ERRnn" internal errors.
    case internalError = "ERR"
    /// Generic "ERROR".
    case error = "ERROR"
    /// "?" — command not understood.
    case unknownCommand = "?"

    /// Messages meaning "the vehicle side did not answer" rather than an
    /// adapter fault. Used to decide between "vehicle unavailable" and
    /// "adapter problem".
    public var indicatesNoVehicleResponse: Bool {
        switch self {
        case .noData, .unableToConnect, .canError, .busInitError, .busError, .busBusy: return true
        default: return false
        }
    }
}

/// A complete adapter response (text preceding a `>` prompt), split into
/// meaningful lines and classified.
public struct ELMResponse: Sendable, Equatable {
    public enum LineKind: Sendable, Equatable {
        case ok
        case searching
        case busInitOK
        case message(ELMMessage)
        /// Only hex digits, spaces and an optional "n:" frame-index prefix.
        case hex
        /// Anything else: version strings, voltages, protocol names.
        case text
    }

    public let raw: String
    /// Non-empty trimmed lines, with the command echo and progress lines
    /// ("SEARCHING...", "BUS INIT: ...OK") removed.
    public let lines: [String]
    /// Status/error messages found anywhere in the response.
    public let messages: [ELMMessage]
    /// True if "SEARCHING..." appeared (protocol auto-detection ran).
    public let searched: Bool
    /// True if the first line echoed the command (echo was on).
    public let echoed: Bool

    public init(raw: String, command: String? = nil) {
        self.raw = raw
        var all = raw
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var echoed = false
        if let command, let first = all.first, Self.normalizedCommand(first) == Self.normalizedCommand(command) {
            all.removeFirst()
            echoed = true
        }
        self.echoed = echoed

        var kept: [String] = []
        var messages: [ELMMessage] = []
        var searched = false
        for line in all {
            switch Self.classify(line) {
            case .searching:
                searched = true
            case .busInitOK:
                continue
            case .message(let m):
                messages.append(m)
                kept.append(line)
            default:
                kept.append(line)
            }
        }
        self.lines = kept
        self.messages = messages
        self.searched = searched
    }

    public var isOK: Bool { lines.contains { $0.uppercased() == "OK" } }
    public var isUnknownCommand: Bool { messages.contains(.unknownCommand) }
    public var hasMessages: Bool { !messages.isEmpty }

    /// Lines that look like hex data (candidate OBD frames).
    public var hexLines: [String] { lines.filter { Self.classify($0) == .hex } }

    /// The first line that is plain text (e.g. the ATZ/ATI version banner).
    public var firstTextLine: String? { lines.first { Self.classify($0) == .text } }

    public static func classify(_ line: String) -> LineKind {
        let u = line.uppercased()
        if u == "OK" { return .ok }
        if u == "?" { return .message(.unknownCommand) }
        if u.hasPrefix("SEARCHING") { return .searching }
        if u.hasPrefix("BUS INIT") {
            return u.contains("ERROR") ? .message(.busInitError) : .busInitOK
        }
        // Order matters: "NO DATA" must be checked before "DATA ERROR"
        // (it does not contain it, but keep specific phrases first anyway).
        let phrases: [(String, ELMMessage)] = [
            ("NO DATA", .noData),
            ("UNABLE TO CONNECT", .unableToConnect),
            ("CAN ERROR", .canError),
            ("BUS BUSY", .busBusy),
            ("BUS ERROR", .busError),
            ("BUFFER FULL", .bufferFull),
            ("DATA ERROR", .dataError),
            ("RX ERROR", .rxError),
            ("FB ERROR", .feedbackError),
            ("LV RESET", .lowVoltageReset),
            ("STOPPED", .stopped),
            ("ACT ALERT", .activityAlert),
            ("LP ALERT", .lowPowerAlert),
        ]
        for (phrase, message) in phrases where u.contains(phrase) {
            return .message(message)
        }
        if u.hasPrefix("ERR"), u.count == 5, u.dropFirst(3).allSatisfy(\.isNumber) {
            return .message(.internalError)
        }
        if u == "ERROR" { return .message(.error) }
        if isHexLine(u) { return .hex }
        return .text
    }

    /// "41 0C 1A F8", "7E8 04 41 0C 1A F8", "410C1AF8", "0: 49 02 01 31".
    static func isHexLine(_ upper: String) -> Bool {
        var body = Substring(upper)
        if let colon = body.firstIndex(of: ":") {
            let prefix = body[..<colon].trimmingCharacters(in: .whitespaces)
            guard prefix.count == 1, Hex.isHexDigit(prefix.first!) else { return false }
            body = body[body.index(after: colon)...]
        }
        var sawDigit = false
        for c in body {
            if c == " " { continue }
            guard Hex.isHexDigit(c) else { return false }
            sawDigit = true
        }
        return sawDigit
    }

    static func normalizedCommand(_ s: String) -> String {
        s.uppercased().filter { !$0.isWhitespace }
    }
}

extension ELMResponse {
    /// Extracts "1.5" / "2.3" / "1.4b" from a banner such as "ELM327 v1.5".
    /// Note: clones may claim any version; this is what the adapter *reports*.
    public static func elmVersion(fromBanner text: String) -> String? {
        let tokens = text.split(separator: " ")
        guard let i = tokens.firstIndex(where: { $0.uppercased() == "ELM327" }), i + 1 < tokens.count else {
            return nil
        }
        var version = tokens[i + 1]
        if version.first == "v" || version.first == "V" { version = version.dropFirst() }
        return version.isEmpty ? nil : String(version)
    }
}
