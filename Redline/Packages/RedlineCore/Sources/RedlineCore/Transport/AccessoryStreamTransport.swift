import Foundation

/// Platform side of a stream-based adapter link: on iOS, an External
/// Accessory session (`EASession`) to an MFi accessory such as the
/// OBDLink MX+. The session owns the I/O thread its streams are scheduled on.
public protocol AccessoryStreamSession: AnyObject, Sendable {
    /// Accessory metadata and link facts for the debug console.
    var details: TransportLinkDetails { get }

    /// On the I/O thread: create the pump with `makePump` (passing the
    /// session's streams), schedule and open both streams, and from then on
    /// forward every stream event to `pump.handle(_:on:errorDescription:)` on
    /// that thread. A system-level accessory disconnect must be reported with
    /// `pump.fail(_:)`.
    func start(makePump: @escaping @Sendable (any ByteInputStream, any ByteOutputStream) -> StreamPump)

    /// Runs `block` on the I/O thread. After `invalidate()` blocks may be
    /// dropped; callers must not rely on them running.
    func perform(_ block: @escaping @Sendable () -> Void)

    /// Closes and unschedules both streams, releases the session and stops
    /// the I/O thread. Idempotent.
    func invalidate()
}

/// Finds the accessory and opens a session to it.
public protocol AccessoryStreamConnector: Sendable {
    /// Waits up to `timeout` for the accessory to be connected to the iPhone,
    /// then opens a session. Must honour task cancellation. Throws
    /// `TransportError` with a user-facing reason.
    func connect(timeout: Duration, log: CommLog) async throws -> any AccessoryStreamSession
}

/// `OBDTransport` over a pair of byte streams to an accessory (External
/// Accessory on iOS; mock streams in tests).
///
/// Like the BLE transport, it moves bytes only: it never composes a command.
/// Every byte it writes comes from `write(_:)`, whose only caller is
/// `ELM327Session` (after the read-only gate). Unlike BLE there is nothing to
/// probe: the accessory protocol string identifies the data channel.
public final class AccessoryStreamTransport: OBDTransport, @unchecked Sendable {
    public let identity: TransportIdentity
    private let connector: any AccessoryStreamConnector
    private let connectTimeout: Duration
    private let openTimeout: Duration

    private struct Current {
        var generation = 0
        var closingByUs = false
        var session: (any AccessoryStreamSession)?
        var pump: StreamPump?
        var continuation: AsyncStream<TransportEvent>.Continuation?
        var openWaiter: OneShot?
        var isOpen = false
        var details = TransportLinkDetails()
        var nextWrite: UInt64 = 0
        var writes: [UInt64: CheckedContinuation<Void, Error>] = [:]
    }

    private let state = Locked(Current())

    public init(identity: TransportIdentity, connector: any AccessoryStreamConnector,
                connectTimeout: Duration = .seconds(10), openTimeout: Duration = .seconds(5)) {
        self.identity = identity
        self.connector = connector
        self.connectTimeout = connectTimeout
        self.openTimeout = openTimeout
    }

    // MARK: OBDTransport

    public func open(log: CommLog) async throws -> AsyncStream<TransportEvent> {
        let generation = state.withLock { s -> Int in
            s.generation += 1
            s.closingByUs = false
            s.isOpen = false
            s.details = TransportLinkDetails()
            return s.generation
        }
        let session = try await connector.connect(timeout: connectTimeout, log: log)
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        let opened = OneShot()
        let superseded = state.withLock { s -> Bool in
            guard s.generation == generation, !s.closingByUs else { return true }
            s.session = session
            s.continuation = continuation
            s.openWaiter = opened
            s.details = session.details
            return false
        }
        if superseded || Task.isCancelled {
            session.invalidate()
            continuation.finish()
            throw CancellationError()
        }
        do {
            try await withTaskCancellationHandler {
                try await opened.wait {
                    // Strong captures: the session/pump ↔ transport cycle is
                    // broken by `teardown`, which every close path runs.
                    session.start { input, output in
                        let pump = StreamPump(input: input, output: output, callbacks: .init(
                            opened: { opened.fire(nil) },
                            received: { data, at in continuation.yield(.received(data, at: at)) },
                            closed: { error in self.linkClosed(generation: generation, error: error) }
                        ))
                        self.state.withLock { s in
                            if s.generation == generation { s.pump = pump }
                        }
                        return pump
                    }
                    let timeout = self.openTimeout
                    Task {
                        try? await Task.sleep(for: timeout)
                        opened.fire(TransportError.connectFailed(
                            "the accessory's data streams did not open within \(timeout)"))
                    }
                }
            } onCancel: {
                opened.fire(CancellationError())
            }
        } catch {
            teardown(generation: generation, event: nil)
            throw error
        }
        let stillCurrent = state.withLock { s -> Bool in
            guard s.generation == generation, !s.closingByUs, s.session != nil else { return false }
            s.isOpen = true
            return true
        }
        guard stillCurrent else {
            teardown(generation: generation, event: nil)
            throw TransportError.disconnected("closed while opening")
        }
        log.info("Accessory streams open")
        return stream
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let target = state.withLock { s -> (UInt64, any AccessoryStreamSession, StreamPump)? in
                guard s.isOpen, let session = s.session, let pump = s.pump else { return nil }
                s.nextWrite += 1
                s.writes[s.nextWrite] = c
                return (s.nextWrite, session, pump)
            }
            guard let (id, session, pump) = target else {
                c.resume(throwing: TransportError.notOpen)
                return
            }
            session.perform {
                pump.send(data) { error in self.completeWrite(id, error) }
            }
        }
    }

    public func close() async {
        let (session, pump, continuation, waiter, writes) = state.withLock { s in
            s.closingByUs = true
            s.isOpen = false
            let taken = (s.session, s.pump, s.continuation, s.openWaiter, s.writes)
            s.session = nil
            s.pump = nil
            s.continuation = nil
            s.openWaiter = nil
            s.writes.removeAll()
            return taken
        }
        waiter?.fire(TransportError.disconnected("closed while opening"))
        for (_, w) in writes { w.resume(throwing: TransportError.notOpen) }
        if let session, let pump {
            session.perform { pump.shutdown() }
        }
        session?.invalidate()
        continuation?.yield(.closed(nil))
        continuation?.finish()
    }

    public func linkDetails() async -> TransportLinkDetails {
        state.withLock { $0.details }
    }

    // MARK: Private

    private func completeWrite(_ id: UInt64, _ error: TransportError?) {
        guard let waiter = state.withLock({ $0.writes.removeValue(forKey: id) }) else { return }
        if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume()
        }
    }

    /// The pump closed (stream error, end of stream, accessory disconnect, or
    /// our own shutdown).
    private func linkClosed(generation: Int, error: TransportError?) {
        let byUs = state.withLock { $0.closingByUs }
        teardown(generation: generation, event: .closed(byUs ? nil : (error ?? .disconnected(nil))))
    }

    /// Releases everything belonging to `generation`; yields `event` first.
    private func teardown(generation: Int, event: TransportEvent?) {
        let taken = state.withLock { s -> (session: (any AccessoryStreamSession)?, continuation: AsyncStream<TransportEvent>.Continuation?,
                                          waiter: OneShot?, writes: [UInt64: CheckedContinuation<Void, Error>])? in
            guard s.generation == generation else { return nil }
            let taken = (s.session, s.continuation, s.openWaiter, s.writes)
            s.session = nil
            s.pump = nil
            s.continuation = nil
            s.openWaiter = nil
            s.writes.removeAll()
            s.isOpen = false
            return taken
        }
        guard let taken else { return }
        let reason: TransportError
        if case .closed(let e)? = event, let e { reason = e } else { reason = .notOpen }
        taken.waiter?.fire(reason)
        for (_, w) in taken.writes { w.resume(throwing: reason) }
        taken.session?.invalidate()
        if let event { taken.continuation?.yield(event) }
        taken.continuation?.finish()
    }
}

/// Resumes one waiter exactly once with the first outcome fired.
final class OneShot: Sendable {
    private struct State {
        var waiter: CheckedContinuation<Void, Error>?
        var outcome: (any Error)??
    }

    private let state = Locked(State())

    /// Runs `arm` (which must eventually lead to `fire`) and waits.
    func wait(_ arm: () -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let early = state.withLock { s -> (any Error)?? in
                if let outcome = s.outcome { return .some(outcome) }
                s.waiter = c
                return nil
            }
            if let early {
                if let error = early { c.resume(throwing: error) } else { c.resume() }
                return
            }
            arm()
        }
    }

    /// `nil` = success. Later calls are ignored.
    func fire(_ error: (any Error)?) {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Error>? in
            guard s.outcome == nil else { return nil }
            s.outcome = .some(error)
            let w = s.waiter
            s.waiter = nil
            return w
        }
        guard let waiter else { return }
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }
}
