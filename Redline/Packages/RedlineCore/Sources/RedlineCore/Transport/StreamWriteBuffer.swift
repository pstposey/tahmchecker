import Foundation

/// Outbound bytes for a byte stream that may accept only part of a write and
/// later signals that it has space again (`OutputStream` semantics, as used
/// by External Accessory sessions).
///
/// A pure value type, so the flow control is unit-tested without hardware.
/// Each enqueued message gets a ticket that completes only when **all** of
/// its bytes were accepted, in order.
public struct StreamWriteBuffer: Sendable {
    private struct Pending: Sendable {
        let ticket: UInt64
        let data: Data
        var offset: Int
    }

    public struct DrainOutcome: Sendable, Equatable {
        /// Tickets whose bytes were all accepted, in order.
        public var completed: [UInt64] = []
        /// The stream reported an error (`write` returned < 0).
        public var failed = false
        public var bytesWritten = 0
    }

    private var queue: [Pending] = []
    private var nextTicket: UInt64 = 0

    public init() {}

    public var isEmpty: Bool { queue.isEmpty }
    public var pendingByteCount: Int { queue.reduce(0) { $0 + ($1.data.count - $1.offset) } }

    /// Queues `data`; returns its ticket. Empty data completes on the next drain.
    public mutating func enqueue(_ data: Data) -> UInt64 {
        nextTicket += 1
        queue.append(Pending(ticket: nextTicket, data: data, offset: 0))
        return nextTicket
    }

    /// Writes as much as the stream accepts. `write` receives the next
    /// unwritten bytes (at most `maxChunk`) and returns how many it took:
    /// > 0 accepted, 0 = no space now (stop until the stream signals space),
    /// < 0 = stream error (everything still queued is left for `removeAll`).
    public mutating func drain(maxChunk: Int = 512, _ write: (Data) -> Int) -> DrainOutcome {
        var outcome = DrainOutcome()
        while var head = queue.first {
            if head.offset >= head.data.count {
                queue.removeFirst()
                outcome.completed.append(head.ticket)
                continue
            }
            let end = min(head.offset + max(1, maxChunk), head.data.count)
            let chunk = head.data.subdata(in: (head.data.startIndex + head.offset)..<(head.data.startIndex + end))
            let n = write(chunk)
            if n < 0 {
                outcome.failed = true
                return outcome
            }
            if n == 0 { return outcome }
            let accepted = min(n, chunk.count)
            head.offset += accepted
            outcome.bytesWritten += accepted
            queue[0] = head
        }
        return outcome
    }

    /// Drops everything queued (link closed); returns the tickets to fail.
    public mutating func removeAll() -> [UInt64] {
        let tickets = queue.map(\.ticket)
        queue.removeAll()
        return tickets
    }
}
