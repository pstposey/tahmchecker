/// Splits the adapter's byte stream into complete responses.
///
/// The ELM327 signals "ready for the next command" by printing the `>` prompt
/// (ELM327 datasheet; corroborated by the Linux `can327` driver docs). Every
/// response is therefore "all bytes since the previous prompt". The prompt
/// never appears inside response text (error markers such as `<DATA ERROR`
/// use `<`, not `>`).
///
/// BLE notifications can split a response at arbitrary byte boundaries, so
/// this type buffers partial data across calls.
public struct ELMResponseFramer: Sendable {
    public static let prompt: UInt8 = 0x3E // ">"

    /// Upper bound on buffered bytes without a prompt. Protects against a
    /// misbehaving link (e.g. a monitor-mode flood) growing memory unbounded.
    public let maxBufferedBytes: Int
    private var buffer: [UInt8] = []
    public private(set) var overflowCount = 0

    public init(maxBufferedBytes: Int = 8_192) {
        self.maxBufferedBytes = maxBufferedBytes
        buffer.reserveCapacity(256)
    }

    /// Appends received bytes; returns the text of every response completed
    /// by a prompt within them, in order.
    public mutating func append(_ bytes: some Sequence<UInt8>) -> [String] {
        var completed: [String] = []
        for b in bytes {
            switch b {
            case Self.prompt:
                completed.append(String(decoding: buffer, as: UTF8.self))
                buffer.removeAll(keepingCapacity: true)
            case 0x00:
                // Some clones emit NUL padding; it carries no information.
                continue
            default:
                if buffer.count >= maxBufferedBytes {
                    buffer.removeFirst(buffer.count / 2)
                    overflowCount += 1
                }
                buffer.append(b)
            }
        }
        return completed
    }

    /// True when non-whitespace bytes are waiting for a prompt.
    public var hasPartialResponse: Bool {
        buffer.contains { $0 != 0x0D && $0 != 0x0A && $0 != 0x20 }
    }

    public var partialText: String { String(decoding: buffer, as: UTF8.self) }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}
