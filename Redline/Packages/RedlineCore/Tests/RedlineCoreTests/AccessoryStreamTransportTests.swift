import Foundation
import Testing
@testable import RedlineCore

// MARK: - Mock platform (stands in for EASession streams; NOT hardware)

/// Input stream fed by the test (queue-confined to the mock session's queue).
final class FakeInputStream: ByteInputStream, @unchecked Sendable {
    private var pending = Data()
    var failNextRead = false

    func append(_ data: Data) { pending.append(data) }

    var hasBytesAvailable: Bool { failNextRead || !pending.isEmpty }

    func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        if failNextRead { failNextRead = false; return -1 }
        let n = min(len, pending.count)
        pending.copyBytes(to: buffer, count: n)
        pending.removeFirst(n)
        return n
    }
}

/// Output stream that accepts at most `maxPerWrite` bytes per call and then
/// reports "no space" until the session signals space again — the partial
/// write / flow-control behaviour `OutputStream` allows.
final class FakeOutputStream: ByteOutputStream, @unchecked Sendable {
    var hasSpaceAvailable = true
    let maxPerWrite: Int
    let throttle: Bool
    var failNextWrite = false
    var stuck = false
    private(set) var written = Data()
    private(set) var writeCalls = 0
    var onWrite: (Data) -> Void = { _ in }
    var onSpaceConsumed: () -> Void = {}

    init(maxPerWrite: Int, throttle: Bool) {
        self.maxPerWrite = maxPerWrite
        self.throttle = throttle
    }

    func write(_ buffer: UnsafePointer<UInt8>, maxLength len: Int) -> Int {
        if failNextWrite { return -1 }
        guard hasSpaceAvailable, !stuck else { return 0 }
        let n = min(len, maxPerWrite)
        let chunk = Data(bytes: buffer, count: n)
        written.append(chunk)
        writeCalls += 1
        onWrite(chunk)
        if throttle {
            hasSpaceAvailable = false
            onSpaceConsumed()
        }
        return n
    }
}

/// Mock accessory session: a serial queue plays the I/O thread; an optional
/// emulated ELM327 (the same emulator the simulator uses) sits behind the
/// streams.
final class MockAccessorySession: AccessoryStreamSession, @unchecked Sendable {
    let queue = DispatchQueue(label: "redline.test.accessory-io")
    let input = FakeInputStream()
    let output: FakeOutputStream
    let device: SimulatedELM327Transport?
    let opensStreams: Bool
    private(set) var pump: StreamPump?
    private let invalidatedFlag = Locked(false)
    private var forward: AsyncStream<Data>.Continuation?
    var isInvalidated: Bool { invalidatedFlag.withLock { $0 } }

    let details = TransportLinkDetails(items: [.init("Transport", "Mock accessory streams (test)")])

    init(device: SimulatedELM327Transport?, opensStreams: Bool = true, maxPerWrite: Int = 3) {
        self.device = device
        self.opensStreams = opensStreams
        self.output = FakeOutputStream(maxPerWrite: maxPerWrite, throttle: true)
    }

    /// Connects the emulated adapter: bytes written to the output stream reach
    /// it in order; its replies arrive on the input stream.
    func attachDevice() async throws {
        guard let device else { return }
        let replies = try await device.open(log: CommLog())
        Task { [weak self] in
            for await event in replies {
                guard case .received(let data, _) = event else { continue }
                self?.deliver(data)
            }
        }
        let (toDevice, continuation) = AsyncStream.makeStream(of: Data.self)
        forward = continuation
        Task {
            for await chunk in toDevice { try? await device.write(chunk) }
        }
        output.onWrite = { chunk in continuation.yield(chunk) }
        // Test-only cycle (output → closure → session); sessions are few.
        output.onSpaceConsumed = {
            self.queue.asyncAfter(deadline: .now() + .milliseconds(1)) {
                self.output.hasSpaceAvailable = true
                self.pump?.handle(.hasSpaceAvailable, on: .output)
            }
        }
    }

    func start(makePump: @escaping @Sendable (any ByteInputStream, any ByteOutputStream) -> StreamPump) {
        queue.async {
            let pump = makePump(self.input, self.output)
            self.pump = pump
            guard self.opensStreams else { return }
            pump.handle(.openCompleted, on: .input)
            pump.handle(.openCompleted, on: .output)
            pump.handle(.hasSpaceAvailable, on: .output)
        }
    }

    func perform(_ block: @escaping @Sendable () -> Void) {
        guard !isInvalidated else { return }
        queue.async(execute: block)
    }

    func invalidate() {
        invalidatedFlag.withLock { $0 = true }
        forward?.finish()
    }

    // Test hooks
    func deliver(_ data: Data) {
        queue.async {
            self.input.append(data)
            self.pump?.handle(.hasBytesAvailable, on: .input)
        }
    }

    func disconnectAccessory() {
        queue.async { self.pump?.fail(.disconnected("accessory disconnected (EAAccessoryDidDisconnect)")) }
    }

    func streamError(on side: StreamPump.Side) {
        queue.async { self.pump?.handle(.errorOccurred, on: side, errorDescription: "test error") }
    }

    func sync() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
    }
}

final class MockAccessoryConnector: AccessoryStreamConnector, @unchecked Sendable {
    enum Behavior: Sendable {
        case device
        case noAccessory
        case waitForever
        case streamsNeverOpen
    }

    let behavior: Locked<Behavior>
    let sessions = Locked<[MockAccessorySession]>([])
    let connectCalls = Locked(0)
    let cancelledWaits = Locked(0)

    init(_ behavior: Behavior) {
        self.behavior = Locked(behavior)
    }

    var lastSession: MockAccessorySession? { sessions.withLock { $0.last } }
    var devices: [SimulatedELM327Transport] { sessions.withLock { $0.compactMap(\.device) } }

    func connect(timeout: Duration, log: CommLog) async throws -> any AccessoryStreamSession {
        connectCalls.withLock { $0 += 1 }
        switch behavior.withLock({ $0 }) {
        case .noAccessory:
            try await Task.sleep(for: .milliseconds(30))
            throw TransportError.unavailable("No OBDLink MX+ connected to this iPhone (mock)")
        case .waitForever:
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                cancelledWaits.withLock { $0 += 1 }
                throw CancellationError()
            }
            throw CancellationError()
        case .streamsNeverOpen:
            let s = MockAccessorySession(device: nil, opensStreams: false)
            sessions.withLock { $0.append(s) }
            return s
        case .device:
            let s = MockAccessorySession(device: SimulatedELM327Transport())
            try await s.attachDevice()
            sessions.withLock { $0.append(s) }
            return s
        }
    }
}

private let mxIdentity = TransportIdentity(kind: .externalAccessory, name: "Mock MFi adapter", identifier: "mock-accessory")

// MARK: - Write buffer

@Suite("Stream transport: write buffer")
struct StreamWriteBufferTests {
    @Test func partialWritesCompleteInOrder() {
        var buffer = StreamWriteBuffer()
        let a = buffer.enqueue(Data("010C\r".utf8))
        let b = buffer.enqueue(Data("0105\r".utf8))
        var sink = Data()
        // Accept 2 bytes per call, then "no space" after 3 calls.
        var calls = 0
        var out = buffer.drain { chunk in
            calls += 1
            guard calls <= 3 else { return 0 }
            sink.append(chunk.prefix(2))
            return min(2, chunk.count)
        }
        // 2 + 2 + 1 bytes: the third call finishes "010C\r"; "0105\r" waits.
        #expect(out.completed == [a])
        #expect(out.bytesWritten == 5)
        #expect(buffer.pendingByteCount == 5)
        out = buffer.drain { chunk in sink.append(chunk); return chunk.count }
        #expect(out.completed == [b])
        #expect(String(decoding: sink, as: UTF8.self) == "010C\r0105\r")
        #expect(buffer.isEmpty)
    }

    @Test func errorStopsAndLeavesBytesQueued() {
        var buffer = StreamWriteBuffer()
        let a = buffer.enqueue(Data("ATZ\r".utf8))
        let out = buffer.drain { _ in -1 }
        #expect(out.failed && out.completed.isEmpty)
        #expect(buffer.removeAll() == [a])
        #expect(buffer.isEmpty)
    }

    @Test func chunksNeverExceedMaxChunk() {
        var buffer = StreamWriteBuffer()
        _ = buffer.enqueue(Data(repeating: 0x41, count: 1000))
        var sizes: [Int] = []
        _ = buffer.drain(maxChunk: 128) { chunk in sizes.append(chunk.count); return chunk.count }
        #expect(sizes.allSatisfy { $0 <= 128 } && sizes.reduce(0, +) == 1000)
    }
}

// MARK: - Pump

@Suite("Stream transport: pump")
struct StreamPumpTests {
    final class Events: @unchecked Sendable {
        let lock = NSLock()
        var opened = 0
        var received = Data()
        var closed: [TransportError?] = []
    }

    func makePump(_ out: FakeOutputStream, _ input: FakeInputStream = FakeInputStream(), _ events: Events) -> StreamPump {
        StreamPump(input: input, output: out, callbacks: .init(
            opened: { events.lock.withLock { events.opened += 1 } },
            received: { d, _ in events.lock.withLock { events.received.append(d) } },
            closed: { e in events.lock.withLock { events.closed.append(e) } }))
    }

    @Test func nothingIsWrittenUntilBothStreamsOpen() {
        let out = FakeOutputStream(maxPerWrite: 100, throttle: false)
        let events = Events()
        let pump = makePump(out, FakeInputStream(), events)
        nonisolated(unsafe) var done: TransportError?? = nil
        pump.send(Data("ATZ\r".utf8)) { done = .some($0) }
        pump.handle(.openCompleted, on: .input)
        pump.handle(.hasSpaceAvailable, on: .output) // space before open: still no write
        #expect(out.written.isEmpty && events.opened == 0)
        pump.handle(.openCompleted, on: .output)
        #expect(events.opened == 1)
        #expect(String(decoding: out.written, as: UTF8.self) == "ATZ\r")
        #expect(done == .some(nil))
    }

    @Test func flowControlResumesOnSpaceAvailable() {
        let out = FakeOutputStream(maxPerWrite: 2, throttle: true)
        let events = Events()
        let pump = makePump(out, FakeInputStream(), events)
        pump.handle([.openCompleted], on: .input)
        pump.handle([.openCompleted], on: .output)
        nonisolated(unsafe) var completed = false
        pump.send(Data("0105\r".utf8)) { completed = $0 == nil }
        #expect(out.written.isEmpty) // no has-space event yet: nothing written
        pump.handle(.hasSpaceAvailable, on: .output)
        #expect(out.written.count == 2 && !completed) // one write per event; then wait
        for _ in 0..<5 {
            out.hasSpaceAvailable = true
            pump.handle(.hasSpaceAvailable, on: .output)
        }
        #expect(String(decoding: out.written, as: UTF8.self) == "0105\r")
        #expect(completed)
        #expect(pump.bytesWritten == 5)
    }

    @Test func writeErrorFailsPendingAndClosesOnce() {
        let out = FakeOutputStream(maxPerWrite: 100, throttle: false)
        out.failNextWrite = true
        let events = Events()
        let pump = makePump(out, FakeInputStream(), events)
        pump.handle(.openCompleted, on: .input)
        pump.handle(.openCompleted, on: .output)
        pump.handle(.hasSpaceAvailable, on: .output)
        nonisolated(unsafe) var result: TransportError?? = nil
        pump.send(Data("010C\r".utf8)) { result = .some($0) }
        if case .some(.some(.writeFailed)) = result {} else { Issue.record("expected writeFailed, got \(String(describing: result))") }
        #expect(events.closed.count == 1)
        pump.handle(.errorOccurred, on: .output) // ignored after close
        pump.handle(.hasBytesAvailable, on: .input)
        #expect(events.closed.count == 1)
        nonisolated(unsafe) var late: TransportError?? = nil
        pump.send(Data("0105\r".utf8)) { late = .some($0) }
        #expect(late == .some(.notOpen))
    }

    @Test func readsEverythingAvailableInOrder() {
        let input = FakeInputStream()
        let events = Events()
        let pump = makePump(FakeOutputStream(maxPerWrite: 1, throttle: false), input, events)
        pump.handle(.openCompleted, on: .input)
        pump.handle(.openCompleted, on: .output)
        input.append(Data("41 0C 1A F8\r\r".utf8))
        input.append(Data(">".utf8))
        pump.handle(.hasBytesAvailable, on: .input)
        #expect(String(decoding: events.received, as: UTF8.self) == "41 0C 1A F8\r\r>")
        #expect(pump.bytesRead == 14)
    }

    @Test func endAndErrorEventsReportWhyTheLinkClosed() {
        let events = Events()
        let pump = makePump(FakeOutputStream(maxPerWrite: 1, throttle: false), FakeInputStream(), events)
        pump.handle(.openCompleted, on: .input)
        pump.handle(.endEncountered, on: .input)
        #expect(events.closed == [.disconnected("the accessory closed the input stream")])
        let events2 = Events()
        let pump2 = makePump(FakeOutputStream(maxPerWrite: 1, throttle: false), FakeInputStream(), events2)
        pump2.handle(.errorOccurred, on: .output, errorDescription: "Broken pipe")
        #expect(events2.closed == [.disconnected("output stream error: Broken pipe")])
        let events3 = Events()
        let pump3 = makePump(FakeOutputStream(maxPerWrite: 1, throttle: false), FakeInputStream(), events3)
        pump3.shutdown()
        #expect(events3.closed == [nil]) // orderly close by Redline
    }
}

// MARK: - Transport lifecycle (mock accessory)

@Suite("Stream transport: lifecycle with mock accessory")
struct AccessoryStreamTransportTests {
    @Test func openWriteReceiveAndOrderlyClose() async throws {
        let connector = MockAccessoryConnector(.device)
        let transport = AccessoryStreamTransport(identity: mxIdentity, connector: connector)
        let events = try await transport.open(log: CommLog())
        try await transport.write(Data("ATI\r".utf8))
        var text = ""
        var closedCleanly = false
        let collector = Task {
            var t = ""
            for await e in events {
                if case .received(let d, _) = e { t += String(decoding: d, as: UTF8.self) }
                if case .closed(let err) = e { return (t, err == nil) }
            }
            return (t, false)
        }
        try await Task.sleep(for: .milliseconds(200))
        await transport.close()
        (text, closedCleanly) = await collector.value
        #expect(text.contains("ELM327"))
        #expect(closedCleanly)
        #expect(connector.lastSession?.isInvalidated == true)
        // Bytes were really split into ≤ 3-byte writes with flow control.
        #expect((connector.lastSession?.output.writeCalls ?? 0) >= 2)
        await #expect(throws: TransportError.notOpen) { try await transport.write(Data("ATI\r".utf8)) }
    }

    @Test func streamsThatNeverOpenTimeOutAndReleaseTheSession() async throws {
        let connector = MockAccessoryConnector(.streamsNeverOpen)
        let transport = AccessoryStreamTransport(identity: mxIdentity, connector: connector,
                                                 openTimeout: .milliseconds(200))
        let start = ContinuousClock().now
        await #expect(throws: TransportError.self) { _ = try await transport.open(log: CommLog()) }
        #expect(ContinuousClock().now - start < .seconds(2))
        #expect(connector.lastSession?.isInvalidated == true)
    }

    @Test func streamErrorClosesTheLinkWithAReason() async throws {
        let connector = MockAccessoryConnector(.device)
        let transport = AccessoryStreamTransport(identity: mxIdentity, connector: connector)
        let events = try await transport.open(log: CommLog())
        connector.lastSession?.streamError(on: .input)
        var reason: TransportError?
        for await e in events { if case .closed(let err) = e { reason = err } }
        #expect(reason == .disconnected("input stream error: test error"))
        #expect(connector.lastSession?.isInvalidated == true)
    }

    @Test func closeWhileAWriteIsStuckFailsTheWrite() async throws {
        let connector = MockAccessoryConnector(.device)
        let transport = AccessoryStreamTransport(identity: mxIdentity, connector: connector)
        _ = try await transport.open(log: CommLog())
        let session = try #require(connector.lastSession)
        session.queue.sync { session.output.stuck = true }
        let write = Task { try await transport.write(Data("010C\r".utf8)) }
        try await Task.sleep(for: .milliseconds(100))
        await transport.close()
        await #expect(throws: TransportError.notOpen) { try await write.value }
    }

    @Test func cancellingOpenWhileWaitingForTheAccessoryReturnsPromptly() async throws {
        let connector = MockAccessoryConnector(.waitForever)
        let transport = AccessoryStreamTransport(identity: mxIdentity, connector: connector)
        let open = Task { try await transport.open(log: CommLog()) }
        try await Task.sleep(for: .milliseconds(100))
        open.cancel()
        await #expect(throws: (any Error).self) { _ = try await open.value }
        #expect(connector.cancelledWaits.withLock { $0 } == 1)
        #expect(connector.sessions.withLock { $0.isEmpty })
    }
}

// MARK: - Engine over the stream transport (adapter-agnostic pipeline)

@MainActor
@Suite("Stream transport: engine end to end (mock accessory)")
struct AccessoryStreamEngineTests {
    @Test func engineStreamsAndEveryTransmittedCommandIsAllowed() async throws {
        let connector = MockAccessoryConnector(.device)
        let engine = TelemetryEngine(options: ELMOptions(physicalAddressing: true, responseCountHint: true),
                                     pollingPreset: .rpmAndBoost)
        engine.start(transport: AccessoryStreamTransport(identity: mxIdentity, connector: connector))
        try await waitUntil(seconds: 20) { (engine.store.channel(.engineRPM)?.sampleCount ?? 0) > 10 }
        #expect(engine.transportIdentity?.kind == .externalAccessory)
        #expect(engine.linkDetails?.items.first?.value == "Mock accessory streams (test)")
        _ = await engine.sendConsoleCommand("04") // refused before reaching the transport
        _ = await engine.sendConsoleCommand("ATSP6")
        await engine.stop()
        let received = connector.devices.flatMap(\.commandsReceived)
        #expect(!received.isEmpty)
        for command in received {
            #expect(CommandSafetyPolicy.evaluateTransmission(command).isAllowed, "adapter received \(command)")
        }
        #expect(!received.contains("04") && !received.contains("ATSP6"))
        // Writes were partial (≤ 3 bytes) and flow-controlled, yet every
        // command arrived intact.
        let session = try #require(connector.lastSession)
        #expect(session.output.writeCalls > received.count)
    }

    @Test func accessoryDisconnectReconnectsWithAFreshSession() async throws {
        let connector = MockAccessoryConnector(.device)
        let engine = TelemetryEngine(pollingPreset: .rpmOnly)
        engine.start(transport: AccessoryStreamTransport(identity: mxIdentity, connector: connector))
        try await waitUntil(seconds: 20) { engine.state == .streaming }
        let first = try #require(connector.lastSession)
        first.disconnectAccessory()
        try await waitUntil(seconds: 5) {
            if case .reconnecting = engine.state { return true }
            return false
        }
        #expect(first.isInvalidated)
        try await waitUntil(seconds: 20) { engine.state == .streaming }
        #expect(connector.connectCalls.withLock { $0 } == 2)
        #expect(connector.lastSession !== first)
        #expect(engine.stateHistory.contains { $0.summary.contains("accessory disconnected") })
        await engine.stop()
        #expect(connector.lastSession?.isInvalidated == true)
    }

    @Test func missingAccessoryIsReportedAndRetried() async throws {
        let connector = MockAccessoryConnector(.noAccessory)
        let engine = TelemetryEngine(pollingPreset: .rpmOnly)
        engine.start(transport: AccessoryStreamTransport(identity: mxIdentity, connector: connector))
        try await waitUntil(seconds: 5) {
            if case .reconnecting = engine.state { return true }
            return false
        }
        #expect(engine.stateHistory.contains { $0.summary.contains("No OBDLink MX+ connected") })
        // The adapter appears (paired / powered on): the retry loop connects.
        connector.behavior.withLock { $0 = .device }
        try await waitUntil(seconds: 20) { engine.state == .streaming }
        await engine.stop()
    }

    @Test func stopWhileWaitingForTheAccessoryIsPrompt() async throws {
        let connector = MockAccessoryConnector(.waitForever)
        let engine = TelemetryEngine(pollingPreset: .rpmOnly)
        engine.start(transport: AccessoryStreamTransport(identity: mxIdentity, connector: connector))
        try await waitUntil(seconds: 5) { connector.connectCalls.withLock { $0 } == 1 }
        let start = ContinuousClock().now
        await engine.stop()
        #expect(ContinuousClock().now - start < .seconds(2))
        #expect(engine.state == .idle)
        #expect(connector.cancelledWaits.withLock { $0 } == 1)
    }
}
