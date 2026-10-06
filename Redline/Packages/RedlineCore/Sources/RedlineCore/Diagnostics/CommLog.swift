import Foundation

/// One line in the developer communication log.
public struct CommLogEntry: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable {
        /// Bytes written to the adapter.
        case tx = "TX"
        /// A complete response (everything before the `>` prompt).
        case rx = "RX"
        /// Lifecycle / link information.
        case info = "--"
        /// Recoverable problem (timeouts, NO DATA bursts, resync).
        case warning = "!!"
        /// Unrecoverable problem for the current operation.
        case error = "XX"
    }

    public let id: UInt64
    public let wallClock: Date
    public let kind: Kind
    public let text: String
    /// Round-trip time for `.rx` entries.
    public let latency: Duration?

    /// Text with CR/LF made visible, for the raw console.
    public var visibleText: String {
        text.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
    }
}

/// Bounded, thread-safe ring buffer of raw adapter traffic and lifecycle notes.
///
/// Written from the ELM session actor and the transport; read by the debug
/// console and the shareable debug report. Bounded so it can be left on.
public final class CommLog: Sendable {
    private struct State {
        var entries: [CommLogEntry] = []
        var nextID: UInt64 = 0
        var version: UInt64 = 0
    }

    public let capacity: Int
    private let state = Locked(State())

    public init(capacity: Int = 1_500) {
        self.capacity = capacity
    }

    public func record(_ kind: CommLogEntry.Kind, _ text: String, latency: Duration? = nil) {
        state.withLock { s in
            s.nextID &+= 1
            s.version &+= 1
            s.entries.append(CommLogEntry(id: s.nextID, wallClock: Date(), kind: kind, text: text, latency: latency))
            if s.entries.count > capacity {
                s.entries.removeFirst(s.entries.count - capacity)
            }
        }
    }

    public func info(_ text: String) { record(.info, text) }
    public func warning(_ text: String) { record(.warning, text) }
    public func error(_ text: String) { record(.error, text) }

    /// Monotonic change counter; lets UI skip work when nothing changed.
    public var version: UInt64 { state.withLock { $0.version } }

    public func entries(last count: Int? = nil) -> [CommLogEntry] {
        state.withLock { s in
            guard let count, count < s.entries.count else { return s.entries }
            return Array(s.entries.suffix(count))
        }
    }

    public func clear() {
        state.withLock { s in
            s.entries.removeAll()
            s.version &+= 1
        }
    }

    /// Plain-text export suitable for pasting into a bug report.
    public func exportText(last count: Int? = nil) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withTime, .withColonSeparatorInTime, .withFractionalSeconds]
        return entries(last: count).map { e in
            var line = "\(formatter.string(from: e.wallClock)) \(e.kind.rawValue) \(e.visibleText)"
            if let latency = e.latency {
                line += String(format: "  [%.1f ms]", latency.milliseconds)
            }
            return line
        }.joined(separator: "\n")
    }
}
