import Foundation

public enum ELMSessionError: Error, Sendable, Equatable, CustomStringConvertible {
    case timedOut(command: String)
    case closed
    /// The adapter did not confirm it was idle even after resync attempts.
    case adapterUnresponsive
    case transport(TransportError)
    case cancelled
    /// The read-only safety policy refused the command; nothing was sent.
    case commandRefused(command: String, reason: String)

    public var description: String {
        switch self {
        case .timedOut(let c): return "Timed out waiting for response to \(c)"
        case .closed: return "Session closed"
        case .adapterUnresponsive: return "Adapter unresponsive"
        case .transport(let e): return e.description
        case .cancelled: return "Cancelled"
        case .commandRefused(let c, let why): return "Refused \(c): \(why)"
        }
    }
}

/// One command/response round trip with timing captured at the session
/// boundary (closest point to the wire available to Swift code).
public struct ELMExchange: Sendable {
    public let command: String
    public let response: ELMResponse
    /// Immediately before the bytes were handed to the transport.
    public let sentAt: MonotonicInstant
    /// Arrival of the first response byte (transport receive timestamp).
    public let firstByteAt: MonotonicInstant?
    /// Arrival of the chunk containing the `>` prompt.
    public let completedAt: MonotonicInstant
    public let wallClock: Date

    public var roundTrip: Duration { completedAt - sentAt }
}

/// Serializes ELM327 commands over an `OBDTransport`.
///
/// The ELM327 is strictly half-duplex at the command level: one command,
/// then wait for the `>` prompt, then the next. Sending a second command
/// early corrupts both responses (and any byte received while the ELM is
/// busy aborts the in-flight request with "STOPPED"). This actor enforces
/// that with a FIFO gate so the poller and the debug console can share the
/// adapter safely.
///
/// Timeouts and resynchronization: if a response does not arrive in time,
/// the session marks itself out of sync. Before the next command it first
/// waits briefly for the late prompt (whose response is discarded so it can
/// never be attributed to the next command). If none arrives, the adapter's
/// state is unknown — it may still be busy, or its prompt was lost — and a
/// command written now could reach a busy adapter. An ELM327 discards the
/// character that interrupts it and might act on the rest of the line, so
/// the session first sends the probe `ATI` (every truncation of which, "TI"
/// or "I", is meaningless to the adapter) until it gets a clean answer
/// followed by silence. Only then is the next real command written.
///
/// A bare CR is never sent: an idle ELM327 repeats its last command on a
/// bare CR, and that command could be a truncated or foreign one.
public actor ELM327Session {
    public struct Timing: Sendable {
        public var defaultTimeout: Duration = .milliseconds(2_000)
        public var latePromptGrace: Duration = .milliseconds(400)
        public var resyncTimeout: Duration = .milliseconds(1_500)
        /// Probe attempts before the adapter is declared unresponsive.
        public var resyncProbeAttempts = 4
        public init() {}
    }

    private struct Completion: Sendable {
        let text: String
        let completedAt: MonotonicInstant
        let firstByteAt: MonotonicInstant?
    }

    public nonisolated let log: CommLog
    public nonisolated let transportIdentity: TransportIdentity
    private let transport: any OBDTransport
    private let timing: Timing
    private let clock = ContinuousClock()

    private var framer = ELMResponseFramer()
    private var receiveTask: Task<Void, Never>?
    public private(set) var isClosed = false

    // FIFO gate: at most one command in flight.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // The single pending-response slot.
    private var nextID: UInt64 = 0
    private var pendingID: UInt64 = 0 // 0 = nothing pending
    private var pendingResult: Result<Completion, ELMSessionError>?
    private var pendingContinuation: CheckedContinuation<Completion, Error>?
    private var pendingFirstByte: MonotonicInstant?
    private var timeoutTask: Task<Void, Never>?

    private var needsResync = false

    private let closeContinuation: AsyncStream<TransportError?>.Continuation
    /// Yields once when the underlying link closes, then finishes.
    public nonisolated let closures: AsyncStream<TransportError?>

    public init(transport: any OBDTransport, log: CommLog, timing: Timing = Timing()) {
        self.transport = transport
        self.transportIdentity = transport.identity
        self.log = log
        self.timing = timing
        (closures, closeContinuation) = AsyncStream.makeStream(of: TransportError?.self)
    }

    /// Begins consuming transport events. Call exactly once, right after
    /// `transport.open`.
    public func start(consuming events: AsyncStream<TransportEvent>) {
        guard receiveTask == nil else { return }
        receiveTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
            // When close() cancelled us it reports the orderly close itself.
            guard !Task.isCancelled else { return }
            await self?.markClosed(.disconnected("event stream ended"))
        }
    }

    /// Number of commands waiting for or holding the adapter.
    public var queueDepth: Int { waiters.count + (busy ? 1 : 0) }

    // MARK: Public API

    /// Sends one command and waits for its prompt-terminated response.
    ///
    /// Every command passes `CommandSafetyPolicy.evaluateTransmission` first;
    /// a refused command throws `.commandRefused` and nothing is written. The
    /// normalized text (exactly what was evaluated) is what goes on the wire.
    public func execute(_ command: String, timeout: Duration? = nil) async throws -> ELMExchange {
        // Evaluate the caller's raw text (so e.g. embedded line breaks are
        // refused, not stripped), then send exactly its normalized form.
        let wire = CommandSafetyPolicy.normalize(command)
        if case .blocked(let why) = CommandSafetyPolicy.evaluateTransmission(command) {
            log.error("REFUSED by read-only policy, not sent: \(Self.oneLine(command)) — \(why)")
            throw ELMSessionError.commandRefused(command: wire, reason: why)
        }
        await acquire()
        defer { release() }
        if Task.isCancelled { throw ELMSessionError.cancelled }
        if isClosed { throw ELMSessionError.closed }

        if needsResync {
            try await resynchronize()
            if isClosed { throw ELMSessionError.closed }
        }
        // The adapter is idle (last prompt seen), so anything buffered
        // without a prompt is noise.
        framer.reset()

        let id = beginPending()
        armTimeout(id, timeout ?? timing.defaultTimeout, command: wire)

        let wallClock = Date()
        let sentAt = clock.now
        log.record(.tx, wire)
        do {
            try await transmit(wire)
        } catch {
            abandonPending(id)
            // Part of the line may have reached the adapter; resync before
            // anything else is written so it can't be completed by our next
            // command.
            needsResync = true
            let te = (error as? TransportError) ?? .writeFailed(String(describing: error))
            log.error("Write failed for \(wire): \(te)")
            throw ELMSessionError.transport(te)
        }

        let completion: Completion
        do {
            completion = try await awaitCompletion(id)
        } catch let e as ELMSessionError {
            if case .timedOut = e {
                log.warning("Timeout after \(wire) — will resync before next command")
            }
            throw e
        }

        let response = ELMResponse(raw: completion.text, command: wire)
        log.record(.rx, completion.text.trimmingCharacters(in: .whitespacesAndNewlines),
                   latency: completion.completedAt - sentAt)
        return ELMExchange(
            command: wire,
            response: response,
            sentAt: sentAt,
            firstByteAt: completion.firstByteAt,
            completedAt: completion.completedAt,
            wallClock: wallClock
        )
    }

    /// The only place bytes are written to the adapter: one gated command
    /// line plus CR. The policy is re-checked here (defense in depth; every
    /// caller already passed it), so nothing can bypass it.
    private func transmit(_ wire: String) async throws {
        guard CommandSafetyPolicy.evaluateTransmission(wire).isAllowed, wire == CommandSafetyPolicy.normalize(wire) else {
            throw ELMSessionError.commandRefused(command: wire, reason: "not transmittable")
        }
        try await transport.write(Data((wire + "\r").utf8))
    }

    public func close() async {
        receiveTask?.cancel()
        receiveTask = nil
        await transport.close()
        markClosed(nil)
    }

    // MARK: Receive path

    private func handle(_ event: TransportEvent) {
        switch event {
        case .received(let data, let at):
            if pendingID != 0, pendingFirstByte == nil {
                pendingFirstByte = at
            }
            for text in framer.append(data) {
                if pendingID != 0 {
                    complete(pendingID, .success(Completion(text: text, completedAt: at, firstByteAt: pendingFirstByte)))
                } else if needsResync {
                    needsResync = false
                    log.warning("Discarded late response: \(Self.oneLine(text))")
                } else {
                    log.warning("Unsolicited data: \(Self.oneLine(text))")
                }
            }
        case .closed(let error):
            markClosed(error)
        }
    }

    private func markClosed(_ error: TransportError?) {
        guard !isClosed else { return }
        isClosed = true
        if pendingID != 0 {
            complete(pendingID, .failure(.transport(error ?? .disconnected(nil))))
        }
        log.info("Session closed\(error.map { ": \($0)" } ?? "")")
        closeContinuation.yield(error)
        closeContinuation.finish()
    }

    // MARK: Pending slot

    private func beginPending() -> UInt64 {
        nextID &+= 1
        pendingID = nextID
        pendingResult = nil
        pendingContinuation = nil
        pendingFirstByte = nil
        return pendingID
    }

    private func armTimeout(_ id: UInt64, _ timeout: Duration, command: String) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.timeoutFired(id, command: command)
        }
    }

    private func timeoutFired(_ id: UInt64, command: String) {
        guard id == pendingID else { return }
        needsResync = true
        complete(id, .failure(.timedOut(command: command)))
    }

    private func complete(_ id: UInt64, _ result: Result<Completion, ELMSessionError>) {
        guard id != 0, id == pendingID else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        if let continuation = pendingContinuation {
            pendingContinuation = nil
            pendingID = 0
            switch result {
            case .success(let c): continuation.resume(returning: c)
            case .failure(let e): continuation.resume(throwing: e)
            }
        } else if pendingResult == nil {
            pendingResult = result
        }
    }

    private func abandonPending(_ id: UInt64) {
        guard id == pendingID else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        pendingID = 0
        pendingResult = nil
        pendingContinuation = nil
    }

    private func awaitCompletion(_ id: UInt64) async throws -> Completion {
        if let result = pendingResult {
            pendingResult = nil
            pendingID = 0
            return try result.get()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Completion, Error>) in
                pendingContinuation = c
            }
        } onCancel: {
            Task { await self.cancelFired(id) }
        }
    }

    private func cancelFired(_ id: UInt64) {
        guard id == pendingID else { return }
        // The adapter will still answer the abandoned command; that answer
        // must be discarded rather than attributed to the next command.
        needsResync = true
        complete(id, .failure(.cancelled))
    }

    // MARK: Resync

    private func resynchronize() async throws {
        log.warning("Resynchronizing: waiting for late prompt")
        if try await waitForPrompt(timing.latePromptGrace) {
            needsResync = false
            return
        }
        if Task.isCancelled { throw ELMSessionError.cancelled }
        // Part of the late answer has arrived: the adapter is still printing,
        // not stuck. Let it finish rather than interrupt it.
        if framer.hasPartialResponse {
            log.warning("Resynchronizing: late response in progress, waiting for it to finish")
            if try await waitForPrompt(timing.resyncTimeout) {
                needsResync = false
                return
            }
            if Task.isCancelled { throw ELMSessionError.cancelled }
        }
        try await confirmIdle()
        needsResync = false
    }

    /// The resync probe. Its truncations ("TI", "I") are not commands, so
    /// sending it to an adapter that may be busy is harmless; any partial
    /// line left in the adapter's buffer plus "ATI" is not hex either.
    static let resyncProbe = "ATI"

    /// Sends the probe until the adapter answers it with plain text and then
    /// stays quiet, which proves it is idle and in step with us.
    private func confirmIdle() async throws {
        for attempt in 1...max(1, timing.resyncProbeAttempts) {
            if Task.isCancelled { throw ELMSessionError.cancelled }
            if isClosed { throw ELMSessionError.closed }
            framer.reset()
            let id = beginPending()
            armTimeout(id, timing.resyncTimeout, command: Self.resyncProbe)
            log.record(.tx, Self.resyncProbe + " (resync probe \(attempt))")
            do {
                try await transmit(Self.resyncProbe)
            } catch {
                abandonPending(id)
                if let e = error as? ELMSessionError { throw e }
                throw ELMSessionError.transport((error as? TransportError) ?? .writeFailed(String(describing: error)))
            }
            let reply: Completion
            do {
                reply = try await awaitCompletion(id)
            } catch let error as ELMSessionError {
                switch error {
                case .transport, .cancelled, .closed: throw error
                default:
                    if isClosed { throw ELMSessionError.closed }
                    log.warning("Resync probe \(attempt): no prompt")
                    continue
                }
            }
            let response = ELMResponse(raw: reply.text, command: Self.resyncProbe)
            log.record(.rx, reply.text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard Self.isCleanProbeReply(response) else {
                log.warning("Resync probe \(attempt): reply was not a clean identification (adapter still settling)")
                continue
            }
            // Something still in flight would produce one more prompt; it
            // must not complete the next command.
            if try await waitForPrompt(timing.latePromptGrace) {
                log.warning("Resync probe \(attempt): another prompt followed; probing again")
                continue
            }
            if Task.isCancelled { throw ELMSessionError.cancelled }
            log.info("Resynchronized: adapter idle")
            return
        }
        log.error("Adapter did not confirm it was idle after \(timing.resyncProbeAttempts) probes")
        throw ELMSessionError.adapterUnresponsive
    }

    /// Identification text only: no hex data, no "?", "STOPPED", "NO DATA"
    /// or other adapter message.
    static func isCleanProbeReply(_ r: ELMResponse) -> Bool {
        r.firstTextLine != nil && r.hexLines.isEmpty && !r.hasMessages && !r.searched
    }

    /// Waits for one prompt and discards its response. Returns false when
    /// none arrives in time; throws if the link closes, so a disconnect during
    /// resync is reported as such rather than as "no prompt".
    private func waitForPrompt(_ timeout: Duration) async throws -> Bool {
        if isClosed { throw ELMSessionError.closed }
        let id = beginPending()
        armTimeout(id, timeout, command: "<late prompt>")
        do {
            let c = try await awaitCompletion(id)
            log.info("Resync discarded late response: \(Self.oneLine(c.text))")
            return true
        } catch let error as ELMSessionError {
            if case .transport = error { throw error }
            if isClosed { throw ELMSessionError.closed }
            return false
        } catch {
            return false
        }
    }

    // MARK: Gate

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
        // Ownership was handed over by `release`; `busy` stays true.
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
    }
}
