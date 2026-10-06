import Foundation

public enum ELMSessionError: Error, Sendable, Equatable, CustomStringConvertible {
    case timedOut(command: String)
    case closed
    /// The adapter did not return a prompt even after a resync attempt.
    case adapterUnresponsive
    /// A timed-out command was not safe to repeat, so the bare-CR resync
    /// (which makes an idle ELM327 repeat the last command) was refused.
    case resyncRefused(lastCommand: String)
    case transport(TransportError)
    case cancelled

    public var description: String {
        switch self {
        case .timedOut(let c): return "Timed out waiting for response to \(c)"
        case .closed: return "Session closed"
        case .adapterUnresponsive: return "Adapter unresponsive"
        case .resyncRefused(let c): return "Cannot resync after non-repeatable command \(c)"
        case .transport(let e): return e.description
        case .cancelled: return "Cancelled"
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
/// never be attributed to the next command). If none arrives it sends a bare
/// CR — the ELM327 either aborts the stuck request ("STOPPED") or, if idle,
/// repeats the last command. Repeating is only acceptable for read-only
/// requests, so the bare-CR step is refused after any command that
/// `CommandSafetyPolicy` does not consider repeat-safe.
public actor ELM327Session {
    public struct Timing: Sendable {
        public var defaultTimeout: Duration = .milliseconds(2_000)
        public var latePromptGrace: Duration = .milliseconds(400)
        public var resyncTimeout: Duration = .milliseconds(1_500)
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
    private var lastCommand = ""
    private var lastCommandRepeatSafe = true

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
    public func execute(_ command: String, timeout: Duration? = nil) async throws -> ELMExchange {
        await acquire()
        defer { release() }
        if Task.isCancelled { throw ELMSessionError.cancelled }
        if isClosed { throw ELMSessionError.closed }

        if needsResync {
            try await resynchronize()
        }
        // The adapter is idle (last prompt seen), so anything buffered
        // without a prompt is noise.
        framer.reset()

        let id = beginPending()
        armTimeout(id, timeout ?? timing.defaultTimeout, command: command)
        lastCommand = command
        lastCommandRepeatSafe = CommandSafetyPolicy.isRepeatSafe(command)

        let wallClock = Date()
        let sentAt = clock.now
        log.record(.tx, command)
        do {
            try await transport.write(Data((command + "\r").utf8))
        } catch {
            abandonPending(id)
            let te = (error as? TransportError) ?? .writeFailed(String(describing: error))
            log.error("Write failed for \(command): \(te)")
            throw ELMSessionError.transport(te)
        }

        let completion: Completion
        do {
            completion = try await awaitCompletion(id)
        } catch let e as ELMSessionError {
            if case .timedOut = e {
                log.warning("Timeout after \(command) — will resync before next command")
            }
            throw e
        }

        let response = ELMResponse(raw: completion.text, command: command)
        log.record(.rx, completion.text.trimmingCharacters(in: .whitespacesAndNewlines),
                   latency: completion.completedAt - sentAt)
        return ELMExchange(
            command: command,
            response: response,
            sentAt: sentAt,
            firstByteAt: completion.firstByteAt,
            completedAt: completion.completedAt,
            wallClock: wallClock
        )
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
        if await waitForPrompt(timing.latePromptGrace) {
            needsResync = false
            return
        }
        if Task.isCancelled { throw ELMSessionError.cancelled }
        // Part of the late answer has arrived: the adapter is still printing,
        // not stuck. A CR now could reach it after its prompt, making an idle
        // ELM327 repeat the command and shifting every later response by one.
        if framer.hasPartialResponse {
            log.warning("Resynchronizing: late response in progress, waiting for it to finish")
            if await waitForPrompt(timing.resyncTimeout) {
                needsResync = false
                return
            }
            if Task.isCancelled { throw ELMSessionError.cancelled }
        }
        guard lastCommandRepeatSafe else {
            log.error("Refusing bare-CR resync: last command \(lastCommand) is not repeat-safe")
            throw ELMSessionError.resyncRefused(lastCommand: lastCommand)
        }
        log.warning("Resynchronizing: sending bare CR")
        framer.reset()
        do {
            try await transport.write(Data("\r".utf8))
        } catch {
            throw ELMSessionError.transport((error as? TransportError) ?? .writeFailed(String(describing: error)))
        }
        if await waitForPrompt(timing.resyncTimeout) {
            // If the late prompt and the CR's own reply crossed, a second
            // prompt follows; absorb it so it can't complete the next command.
            _ = await waitForPrompt(timing.latePromptGrace)
            if Task.isCancelled { throw ELMSessionError.cancelled }
            needsResync = false
            return
        }
        if Task.isCancelled { throw ELMSessionError.cancelled }
        log.error("Adapter did not return a prompt after resync")
        throw ELMSessionError.adapterUnresponsive
    }

    private func waitForPrompt(_ timeout: Duration) async -> Bool {
        let id = beginPending()
        armTimeout(id, timeout, command: "<resync>")
        do {
            let c = try await awaitCompletion(id)
            log.info("Resync discarded: \(Self.oneLine(c.text))")
            return true
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
