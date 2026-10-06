import Foundation

/// The read side of a byte stream. `InputStream` conforms, which is what an
/// External Accessory session (`EASession.inputStream`) provides.
public protocol ByteInputStream: AnyObject {
    var hasBytesAvailable: Bool { get }
    func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int
}

/// The write side of a byte stream (`OutputStream`, `EASession.outputStream`).
public protocol ByteOutputStream: AnyObject {
    var hasSpaceAvailable: Bool { get }
    func write(_ buffer: UnsafePointer<UInt8>, maxLength len: Int) -> Int
}

extension InputStream: ByteInputStream {}
extension OutputStream: ByteOutputStream {}

/// Moves bytes between a pair of Foundation-style streams and Redline's
/// transport layer: tracks that both streams opened, reads on each
/// has-bytes event, writes with partial-write and flow-control handling, and
/// turns stream errors / end-of-stream into one close.
///
/// Non-blocking discipline (Apple DTS guidance for run-loop-scheduled
/// streams): read only after a has-bytes-available event (once per event),
/// write only after a has-space-available event, and track "space
/// available" here instead of trusting the `hasSpaceAvailable` property —
/// after each write, assume no space until the next event.
///
/// It carries bytes only. It never creates data of its own: everything it
/// writes was handed to `send` by the transport, whose only caller is
/// `ELM327Session` (after the read-only gate).
///
/// Confinement: every method must be called on the thread whose run loop the
/// streams are scheduled on (the accessory session's I/O thread). The owner
/// guarantees that; `@unchecked Sendable` only lets blocks carry the pump to
/// that thread.
public final class StreamPump: @unchecked Sendable {
    public enum Side: String, Sendable {
        case input
        case output
    }

    public enum Phase: Sendable, Equatable {
        case opening
        case open
        case closed
    }

    public struct Callbacks: Sendable {
        public var opened: @Sendable () -> Void
        public var received: @Sendable (Data, MonotonicInstant) -> Void
        /// `nil` = closed by us (`shutdown`); otherwise why the link was lost.
        public var closed: @Sendable (TransportError?) -> Void

        public init(opened: @escaping @Sendable () -> Void,
                    received: @escaping @Sendable (Data, MonotonicInstant) -> Void,
                    closed: @escaping @Sendable (TransportError?) -> Void) {
            self.opened = opened
            self.received = received
            self.closed = closed
        }
    }

    private let input: any ByteInputStream
    private let output: any ByteOutputStream
    private let callbacks: Callbacks
    private let readChunk: Int
    private let maxWriteChunk: Int
    private let clock = ContinuousClock()

    private var buffer = StreamWriteBuffer()
    private var completions: [UInt64: @Sendable (TransportError?) -> Void] = [:]
    private var inputOpen = false
    private var outputOpen = false
    /// Set by a has-space-available event, cleared by each write.
    private var outputHasSpace = false
    public private(set) var phase: Phase = .opening
    public private(set) var bytesRead = 0
    public private(set) var bytesWritten = 0

    public init(input: any ByteInputStream, output: any ByteOutputStream, callbacks: Callbacks,
                readChunk: Int = 512, maxWriteChunk: Int = 512) {
        self.input = input
        self.output = output
        self.callbacks = callbacks
        self.readChunk = max(1, readChunk)
        self.maxWriteChunk = max(1, maxWriteChunk)
    }

    /// Forward each `StreamDelegate` event here.
    public func handle(_ event: Stream.Event, on side: Side, errorDescription: String? = nil) {
        guard phase != .closed else { return }
        if event.contains(.openCompleted) {
            switch side {
            case .input: inputOpen = true
            case .output: outputOpen = true
            }
            if inputOpen, outputOpen, phase == .opening {
                phase = .open
                callbacks.opened()
                drain()
            }
        }
        if event.contains(.hasBytesAvailable), side == .input {
            readOnce()
        }
        if event.contains(.hasSpaceAvailable), side == .output {
            outputHasSpace = true
            if phase == .open { drain() }
        }
        guard phase != .closed else { return }
        if event.contains(.errorOccurred) {
            finish(.disconnected("\(side.rawValue) stream error" + (errorDescription.map { ": \($0)" } ?? "")))
        } else if event.contains(.endEncountered) {
            finish(.disconnected("the accessory closed the \(side.rawValue) stream"))
        }
    }

    /// Queues bytes; `completion` runs (on this thread) once all of them were
    /// accepted by the stream, or with an error if the link closes first.
    public func send(_ data: Data, completion: @escaping @Sendable (TransportError?) -> Void) {
        guard phase != .closed else {
            completion(.notOpen)
            return
        }
        let ticket = buffer.enqueue(data)
        completions[ticket] = completion
        if phase == .open { drain() }
    }

    /// The accessory disconnected at the system level (or the session is
    /// being torn down because of an error).
    public func fail(_ error: TransportError) {
        guard phase != .closed else { return }
        finish(error)
    }

    /// Orderly close requested by Redline.
    public func shutdown() {
        guard phase != .closed else { return }
        finish(nil)
    }

    // MARK: Private

    /// One read per has-bytes event; the stream raises another event while
    /// more data is waiting.
    private func readOnce() {
        guard phase != .closed else { return }
        var chunk = [UInt8](repeating: 0, count: readChunk)
        let n = input.read(&chunk, maxLength: chunk.count)
        if n > 0 {
            bytesRead += n
            callbacks.received(Data(chunk[0..<n]), clock.now)
        } else if n < 0 {
            finish(.disconnected("read error on the input stream"))
        }
        // 0: nothing / end of stream; .endEncountered follows.
    }

    private func drain() {
        let output = self.output
        let outcome = buffer.drain(maxChunk: maxWriteChunk) { chunk in
            guard outputHasSpace else { return 0 }
            outputHasSpace = false
            return chunk.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return output.write(base, maxLength: chunk.count)
            }
        }
        bytesWritten += outcome.bytesWritten
        for ticket in outcome.completed {
            completions.removeValue(forKey: ticket)?(nil)
        }
        if outcome.failed {
            finish(.writeFailed("the output stream reported an error"))
        }
    }

    private func finish(_ error: TransportError?) {
        phase = .closed
        let pending = buffer.removeAll()
        for ticket in pending {
            completions.removeValue(forKey: ticket)?(error ?? .notOpen)
        }
        // Tickets completed in this drain were already removed; anything left
        // (none expected) is failed too so no caller can hang.
        for (_, completion) in completions { completion(error ?? .notOpen) }
        completions.removeAll()
        callbacks.closed(error)
    }
}
