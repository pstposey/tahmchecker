import Foundation
import Testing
@testable import RedlineCore

/// A transport whose replies are scripted per command.
final class ScriptedTransport: OBDTransport, @unchecked Sendable {
    enum Reply {
        case text(String, after: Duration)
        /// Never answer (simulates a lost prompt).
        case silence
    }

    let identity = TransportIdentity(kind: .simulated, name: "Scripted", identifier: "scripted")
    private let lock = NSLock()
    private var continuation: AsyncStream<TransportEvent>.Continuation?
    private var script: (String) -> Reply
    private(set) var written: [String] = []

    init(script: @escaping (String) -> Reply) {
        self.script = script
    }

    func open(log: CommLog) async throws -> AsyncStream<TransportEvent> {
        let (stream, c) = AsyncStream.makeStream(of: TransportEvent.self)
        lock.withLock { continuation = c }
        return stream
    }

    func write(_ data: Data) async throws {
        let command = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        let reply = lock.withLock { () -> Reply in
            written.append(command)
            return script(command)
        }
        guard case .text(let text, let delay) = reply else { return }
        Task {
            try? await Task.sleep(for: delay)
            self.send(text)
        }
    }

    func send(_ text: String) {
        let c = lock.withLock { continuation }
        // Deliver in small chunks, like BLE notifications.
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            let end = min(i + 7, bytes.count)
            c?.yield(.received(Data(bytes[i..<end]), at: ContinuousClock().now))
            i = end
        }
    }

    func disconnect() {
        let c = lock.withLock { continuation }
        c?.yield(.closed(.disconnected("test")))
        c?.finish()
    }

    func close() async {
        let c = lock.withLock { continuation }
        c?.finish()
    }

    func linkDetails() async -> TransportLinkDetails { TransportLinkDetails() }

    var writtenCommands: [String] { lock.withLock { written } }
}

@Suite("ELM327 session")
struct SessionTests {
    func makeSession(_ transport: ScriptedTransport, timeout: Duration = .milliseconds(300)) async throws -> ELM327Session {
        var timing = ELM327Session.Timing()
        timing.defaultTimeout = timeout
        timing.latePromptGrace = .milliseconds(150)
        timing.resyncTimeout = .milliseconds(300)
        let session = ELM327Session(transport: transport, log: CommLog(), timing: timing)
        await session.start(consuming: try await transport.open(log: session.log))
        return session
    }

    @Test func roundTripWithTimestamps() async throws {
        let t = ScriptedTransport { _ in .text("41 0C 1A F8 \r\r>", after: .milliseconds(20)) }
        let s = try await makeSession(t)
        let ex = try await s.execute("010C")
        #expect(ex.response.lines == ["41 0C 1A F8"])
        #expect(ex.roundTrip >= .milliseconds(15))
        #expect(ex.firstByteAt != nil)
        #expect(ex.firstByteAt! <= ex.completedAt)
    }

    @Test func concurrentCallersAreSerialized() async throws {
        let t = ScriptedTransport { cmd in .text("ECHO \(cmd)\r\r>", after: .milliseconds(5)) }
        let s = try await makeSession(t)
        try await withThrowingTaskGroup(of: (String, String).self) { group in
            for i in 0..<20 {
                group.addTask {
                    let cmd = String(format: "01%02X", i + 0x10) // 0110…0123 (never 0104)
                    let ex = try await s.execute(cmd)
                    return (cmd, ex.response.lines.first ?? "")
                }
            }
            for try await (cmd, line) in group {
                #expect(line == "ECHO \(cmd)") // never another command's response
            }
        }
    }

    @Test func lateResponseIsDiscardedNotMisattributed() async throws {
        // 0105's answer arrives after its timeout; the next command must get
        // its own answer, not the late one.
        let t = ScriptedTransport { cmd in
            switch cmd {
            case "0105": return .text("41 05 82\r\r>", after: .milliseconds(400))
            default: return .text("41 0C 1A F8\r\r>", after: .milliseconds(10))
            }
        }
        let s = try await makeSession(t, timeout: .milliseconds(250))
        _ = try await s.execute("010C") // an answered command of ours precedes any resync
        await #expect(throws: ELMSessionError.timedOut(command: "0105")) {
            try await s.execute("0105")
        }
        let ex = try await s.execute("010C")
        #expect(ex.response.lines == ["41 0C 1A F8"])
    }

    @Test func lostPromptRecoveredWithProbe() async throws {
        let t = ScriptedTransport { cmd in
            switch cmd {
            case "0105": return .silence
            case "ATI": return .text("ELM327 v1.5\r\r>", after: .milliseconds(10))
            default: return .text("41 0C 1A F8\r\r>", after: .milliseconds(10))
            }
        }
        let s = try await makeSession(t)
        _ = try await s.execute("010C")
        await #expect(throws: ELMSessionError.self) { try await s.execute("0105") }
        let ex = try await s.execute("010C")
        #expect(ex.response.lines == ["41 0C 1A F8"])
        #expect(t.writtenCommands == ["010C", "0105", "ATI", "010C"])
    }

    /// A silent adapter is probed a bounded number of times and declared
    /// unresponsive. No bare CR (which repeats whatever the adapter ran
    /// last, possibly another app's command) is ever sent, and the real
    /// command is never written to an adapter that might still be busy.
    @Test func silentAdapterIsProbedThenDeclaredUnresponsive() async throws {
        let t = ScriptedTransport { _ in .silence }
        let s = try await makeSession(t)
        await #expect(throws: ELMSessionError.self) { try await s.execute("ATZ") }
        await #expect(throws: ELMSessionError.adapterUnresponsive) { try await s.execute("010C") }
        #expect(!t.writtenCommands.contains(""))
        #expect(t.writtenCommands == ["ATZ", "ATI", "ATI", "ATI", "ATI"])
    }

    /// The auditor's race: the late prompt arrives just after the session
    /// gave up waiting. The probe's own answer is followed by that stray
    /// prompt, so the session probes again instead of writing the next
    /// command while the adapter's state is uncertain.
    @Test func strayPromptAfterProbeTriggersAnotherProbe() async throws {
        let t = ScriptedTransport { cmd in
            switch cmd {
            case "0105": return .text("41 05 82\r\r>", after: .milliseconds(560)) // after timeout + grace
            case "ATI": return .text("ELM327 v1.5\r\r>", after: .milliseconds(10))
            default: return .text("41 0C 1A F8\r\r>", after: .milliseconds(10))
            }
        }
        let s = try await makeSession(t) // timeout 300 ms, grace 150 ms, resync 300 ms
        await #expect(throws: ELMSessionError.timedOut(command: "0105")) { try await s.execute("0105") }
        let ex = try await s.execute("010C")
        #expect(ex.response.lines == ["41 0C 1A F8"]) // never the late 0105 answer
        #expect(t.writtenCommands == ["0105", "ATI", "ATI", "010C"])
    }

    /// Replies that show the adapter was interrupted or confused ("STOPPED",
    /// "?", data) are not proof of idleness: the session probes again.
    @Test func unclearProbeRepliesAreRetried() async throws {
        let probes = Locked(0)
        let t = ScriptedTransport { cmd in
            switch cmd {
            case "0105": return .silence
            case "ATI":
                let n = probes.withLock { n -> Int in n += 1; return n }
                switch n {
                case 1: return .text("STOPPED\r\r>", after: .milliseconds(5))
                case 2: return .text("?\r\r>", after: .milliseconds(5))
                default: return .text("ELM327 v1.5\r\r>", after: .milliseconds(5))
                }
            default: return .text("41 0C 1A F8\r\r>", after: .milliseconds(5))
            }
        }
        let s = try await makeSession(t)
        await #expect(throws: ELMSessionError.self) { try await s.execute("0105") }
        _ = try await s.execute("010C")
        #expect(t.writtenCommands == ["0105", "ATI", "ATI", "ATI", "010C"])
    }

    /// If a write fails part-way, part of the line may sit in the adapter's
    /// buffer; the next command must not complete it.
    @Test func failedWriteForcesAProbeBeforeTheNextCommand() async throws {
        final class FlakyWriteTransport: OBDTransport, @unchecked Sendable {
            let inner: ScriptedTransport
            let failNext = Locked(false)
            init(_ inner: ScriptedTransport) { self.inner = inner }
            var identity: TransportIdentity { inner.identity }
            func open(log: CommLog) async throws -> AsyncStream<TransportEvent> { try await inner.open(log: log) }
            func write(_ data: Data) async throws {
                if failNext.withLock({ let v = $0; $0 = false; return v }) { throw TransportError.writeFailed("test") }
                try await inner.write(data)
            }
            func close() async { await inner.close() }
            func linkDetails() async -> TransportLinkDetails { TransportLinkDetails() }
        }
        let t = ScriptedTransport { cmd in
            cmd == "ATI" ? .text("ELM327 v1.5\r\r>", after: .milliseconds(5)) : .text("41 0C 1A F8\r\r>", after: .milliseconds(5))
        }
        let flaky = FlakyWriteTransport(t)
        let s = ELM327Session(transport: flaky, log: CommLog())
        await s.start(consuming: try await flaky.open(log: s.log))
        flaky.failNext.withLock { $0 = true }
        await #expect(throws: ELMSessionError.self) { try await s.execute("0105") }
        _ = try await s.execute("010C")
        #expect(t.writtenCommands == ["ATI", "010C"])
    }

    @Test func disconnectFailsPendingRequest() async throws {
        let t = ScriptedTransport { _ in .silence }
        let s = try await makeSession(t, timeout: .seconds(5))
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            t.disconnect()
        }
        await #expect(throws: ELMSessionError.self) { try await s.execute("010C") }
        #expect(await s.isClosed)
        await #expect(throws: ELMSessionError.closed) { try await s.execute("010C") }
    }

    @Test func cancellationDoesNotHang() async throws {
        let t = ScriptedTransport { _ in .silence }
        let s = try await makeSession(t, timeout: .seconds(10))
        let task = Task { try await s.execute("010C") }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: ELMSessionError.cancelled) { try await task.value }
    }
}

@Suite("Initializer and engine with simulator")
struct SimulatorIntegrationTests {
    @Test func initializerAgainstSimulatedAdapter() async throws {
        let transport = SimulatedELM327Transport()
        let log = CommLog()
        let session = ELM327Session(transport: transport, log: log)
        await session.start(consuming: try await transport.open(log: log))

        let initializer = ELMInitializer()
        var info = try await initializer.initializeAdapter(session)
        #expect(info.reportedVersion == "1.5")
        var support = PIDSupportMap()
        let link = try await initializer.connectToVehicle(session, info: &info, support: &support)
        #expect(link == .connected)
        #expect(info.obdProtocol == .iso_15765_4_can11_500)
        #expect(info.protocolAutoDetected)
        #expect(info.responders == [.can11(0x7E8), .can11(0x7E9)])
        try await initializer.discoverSupport(session, info: info, support: &support)
        #expect(support.isSupported(0x0C))
        #expect(support.isSupported(0x33)) // needs range 0x20 query
        #expect(support.isSupported(0x49)) // needs range 0x40 query
        #expect(!support.isSupported(0x5C)) // oil temp not simulated
        #expect(support.ecus(supporting: 0x0C) == [.can11(0x7E8)])

        let effective = try await initializer.applyRequestOptions(
            session, options: ELMOptions(physicalAddressing: true, responseCountHint: true), info: &info)
        #expect(effective.physicalAddressing)
        #expect(info.physicalRequestHeader == "7E0")
        await session.close()
    }

    @MainActor
    @Test func engineStreamsRealPipelineFromSimulator() async throws {
        let engine = TelemetryEngine(pollingPreset: .rpmAndBoost)
        let sim = SimulatedVehicle(scenario: .idle)
        engine.start(transport: SimulatedELM327Transport(vehicle: sim))

        let rpm = engine.store.channel(.engineRPM)!
        let boost = engine.store.channel(.boost)!
        try await waitUntil(seconds: 15) { rpm.sampleCount >= 10 && boost.latest != nil }

        #expect(engine.state == .streaming)
        #expect(engine.store.sourceKind == .simulated)
        #expect(rpm.latest!.source == .ecuReported)
        #expect(rpm.latest!.ecu == .can11(0x7E8))
        #expect(boost.latest!.source == .calculated)
        #expect(boost.latest!.derivation?.contains("BARO") == true)
        // BARO is the simulator's 83 kPa; boost = MAP − 83.
        let map = engine.store.channel(.manifoldPressure)!.latest!.value
        #expect(abs(boost.latest!.value - (map - 83)) < 0.001)
        #expect(engine.store.channel(.oilTemp)!.displayStatus == .unsupported)
        #expect(engine.polledChannels == [.engineRPM, .manifoldPressure, .barometricPressure, .coolantTemp])
        let snap = engine.performanceSnapshot()
        #expect(snap.totalRequests > 0)
        #expect(snap.medianRoundTripMs != nil)
        await engine.stop()
        #expect(engine.state == .idle)
    }

    @MainActor
    @Test func boostPullProducesPositivePeak() async throws {
        let engine = TelemetryEngine(pollingPreset: .rpmAndBoost)
        let sim = SimulatedVehicle(scenario: .boostPull)
        engine.start(transport: SimulatedELM327Transport(vehicle: sim))
        let boost = engine.store.channel(.boost)!
        try await waitUntil(seconds: 20) { (boost.peak ?? 0) > 60 }
        #expect(boost.peak! > 60)
        engine.store.resetPeaks()
        #expect(boost.peak == nil)
        await engine.stop()
    }

    @MainActor
    @Test func pollingPresetChangeTakesEffect() async throws {
        let engine = TelemetryEngine(pollingPreset: .rpmOnly)
        engine.start(transport: SimulatedELM327Transport())
        try await waitUntil(seconds: 15) { engine.state == .streaming && !engine.polledChannels.isEmpty }
        #expect(engine.polledChannels == [.engineRPM])
        engine.pollingPreset = .turboDashboard
        try await waitUntil(seconds: 5) { engine.polledChannels.contains(.intakeAirTemp) }
        let iat = engine.store.channel(.intakeAirTemp)!
        try await waitUntil(seconds: 5) { iat.latest != nil }
        await engine.stop()
    }

    @MainActor
    @Test func consoleIsReadOnlyAndShared() async throws {
        let engine = TelemetryEngine(pollingPreset: .rpmOnly)
        engine.start(transport: SimulatedELM327Transport())
        try await waitUntil(seconds: 15) { engine.state == .streaming }
        let ok = await engine.sendConsoleCommand("0105")
        #expect(ok.contains("41 05"))
        let blocked = await engine.sendConsoleCommand("04")
        #expect(blocked.hasPrefix("BLOCKED"))
        await engine.stop()
    }
}

@MainActor
func waitUntil(seconds: Double, _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock().now + .seconds(seconds)
    while !condition() {
        if ContinuousClock().now > deadline {
            Issue.record("Condition not met within \(seconds) s")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
@Suite("Debug report")
struct DebugReportTests {
    @Test func reportContainsKeySections() async throws {
        let engine = TelemetryEngine(pollingPreset: .rpmAndBoost)
        engine.start(transport: SimulatedELM327Transport())
        try await waitUntil(seconds: 15) { (engine.store.channel(.engineRPM)?.sampleCount ?? 0) > 5 }
        let report = engine.debugReport(appVersion: "test")
        #expect(report.contains("Source: SIMULATION"))
        #expect(report.contains("ATZ banner: ELM327 v1.5"))
        #expect(report.contains("7E8:"))
        #expect(report.contains("RPM  target 10.0 Hz"))
        #expect(report.contains("TX 010C"))
        await engine.stop()
    }
}

@Suite("Regression: review findings")
struct ReviewRegressionTests {
    func makeSession(_ transport: ScriptedTransport) async throws -> ELM327Session {
        var timing = ELM327Session.Timing()
        timing.defaultTimeout = .milliseconds(300)
        timing.latePromptGrace = .milliseconds(150)
        timing.resyncTimeout = .milliseconds(300)
        let session = ELM327Session(transport: transport, log: CommLog(), timing: timing)
        await session.start(consuming: try await transport.open(log: session.log))
        return session
    }

    /// A late answer still arriving when the grace period ends must be waited
    /// for, not interrupted by a probe.
    @Test func noProbeWhileLateResponseIsInProgress() async throws {
        let t = ScriptedTransport { cmd in
            switch cmd {
            case "010C": return .silence
            case "010D": return .text("41 0D 32\r\r>", after: .milliseconds(120))
            default: return .silence
            }
        }
        let s = try await makeSession(t) // timeout 300 ms, grace 150 ms, resync 300 ms
        await #expect(throws: ELMSessionError.timedOut(command: "010C")) { try await s.execute("010C") }
        // Event-driven (no wall-clock race): the first part of the late answer
        // is already buffered when the next command starts its 150 ms grace
        // wait; the rest (with the prompt) lands after the grace has expired.
        t.send("41 0C 1A")
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            t.send(" F8\r\r>")
        }
        let ex = try await s.execute("010D")
        #expect(ex.response.lines == ["41 0D 32"])
        #expect(t.writtenCommands == ["010C", "010D"]) // no probe was needed
    }

    @Test func cancellationDuringResyncIsReportedAsCancelled() async throws {
        let t = ScriptedTransport { _ in .silence }
        let s = try await makeSession(t)
        await #expect(throws: ELMSessionError.self) { try await s.execute("010C") }
        let task = Task { try await s.execute("010D") }
        try await Task.sleep(for: .milliseconds(40))
        task.cancel()
        await #expect(throws: ELMSessionError.cancelled) { try await task.value }
    }
}

@MainActor
@Suite("Regression: engine lifecycle")
struct EngineLifecycleRegressionTests {
    /// Simulator whose close() takes a while, so stop() is reliably still
    /// mid-teardown when the test issues start() (the new connection uses a
    /// different transport). Every close is slow: under heavy CPU load the
    /// first link can drop by itself before stop(), which used to consume a
    /// one-off slow close and make the precondition flaky.
    final class SlowCloseTransport: OBDTransport, @unchecked Sendable {
        let inner = SimulatedELM327Transport()
        var identity: TransportIdentity { inner.identity }
        func open(log: CommLog) async throws -> AsyncStream<TransportEvent> { try await inner.open(log: log) }
        func write(_ data: Data) async throws { try await inner.write(data) }
        func close() async {
            try? await Task.sleep(for: .seconds(3))
            await inner.close()
        }
        func linkDetails() async -> TransportLinkDetails { await inner.linkDetails() }
    }

    @Test func startDuringStopDoesNotKillNewConnection() async throws {
        let engine = TelemetryEngine(pollingPreset: .rpmOnly)
        engine.autoReconnect = false // a killed connection must not be masked by reconnecting
        engine.start(transport: SlowCloseTransport())
        try await waitUntil(seconds: 15) { engine.state == .streaming }
        let stopping = Task { await engine.stop() }
        try await waitUntil(seconds: 5) { engine.isStopping } // stop() is mid-teardown
        engine.start(transport: SimulatedELM327Transport())
        await stopping.value
        #expect(!engine.isStopping)
        try await waitUntil(seconds: 15) { engine.state == .streaming }
        let rpm = engine.store.channel(.engineRPM)!
        let before = rpm.sampleCount
        try await Task.sleep(for: .seconds(1))
        #expect(engine.state == .streaming) // the new connection was not closed or reported idle
        #expect(rpm.sampleCount > before)
        await engine.stop()
        #expect(engine.state == .idle)
    }

    @Test func orderlyStopIsNotLoggedAsDisconnect() async throws {
        let engine = TelemetryEngine(pollingPreset: .rpmOnly)
        engine.start(transport: SimulatedELM327Transport())
        try await waitUntil(seconds: 15) { engine.state == .streaming }
        await engine.stop()
        #expect(!engine.log.exportText().contains("event stream ended"))
        #expect(engine.adapterInfo == nil)
        #expect(engine.support == nil)
        #expect(engine.linkDetails == nil)
        #expect(engine.polledChannels.isEmpty)
    }

    @Test func metadataFromPreviousSourceIsCleared() async throws {
        final class FailingTransport: OBDTransport, @unchecked Sendable {
            let identity = TransportIdentity(kind: .bluetoothLE, name: "Failing BLE", identifier: "x")
            func open(log: CommLog) async throws -> AsyncStream<TransportEvent> { throw TransportError.connectTimedOut }
            func write(_ data: Data) async throws { throw TransportError.notOpen }
            func close() async {}
            func linkDetails() async -> TransportLinkDetails { TransportLinkDetails() }
        }
        let engine = TelemetryEngine(pollingPreset: .rpmOnly)
        engine.autoReconnect = false
        engine.start(transport: SimulatedELM327Transport())
        try await waitUntil(seconds: 15) { engine.state == .streaming }
        engine.start(transport: FailingTransport())
        try await waitUntil(seconds: 10) { if case .disconnected = engine.state { return true } else { return false } }
        #expect(engine.adapterInfo == nil)
        #expect(engine.linkDetails == nil)
        #expect(engine.support == nil)
        #expect(!engine.debugReport(appVersion: "t").contains("Simulated ELM327"))
        await engine.stop()
    }

    @Test func reconnectBackoffResetsAfterSuccessfulSession() async throws {
        let engine = TelemetryEngine(pollingPreset: .rpmOnly)
        let sim = SimulatedELM327Transport()
        engine.start(transport: sim)
        var attempts: [Int] = []
        for _ in 0..<2 {
            try await waitUntil(seconds: 15) { engine.state == .streaming }
            await sim.close() // link drops
            try await waitUntil(seconds: 5) {
                if case .reconnecting = engine.state { return true } else { return false }
            }
            if case .reconnecting(let n) = engine.state { attempts.append(n) }
        }
        #expect(attempts == [1, 1])
        await engine.stop()
    }

    @Test func rejectedResponseCountHintIsReflectedInEffectiveOptions() async throws {
        var config = SimulatedELM327Transport.Configuration()
        config.supportsResponseCountHint = false
        let engine = TelemetryEngine(options: ELMOptions(responseCountHint: true), pollingPreset: .rpmOnly)
        engine.start(transport: SimulatedELM327Transport(configuration: config))
        try await waitUntil(seconds: 15) { (engine.store.channel(.engineRPM)?.sampleCount ?? 0) > 3 }
        #expect(engine.effectiveOptions?.responseCountHint == false)
        await engine.stop()
    }
}

@MainActor
@Suite("Regression: store accuracy")
struct StoreAccuracyRegressionTests {
    func sample(_ id: ChannelID, _ value: Double, at t: MonotonicInstant) -> TelemetrySample {
        TelemetrySample(channel: id, value: value, source: .ecuReported,
                        timing: SampleTiming(requestedAt: t, receivedAt: t, decodedAt: t))
    }

    @Test func cachedBaroIsNotUsedOnceUnsupported() {
        let store = TelemetryStore()
        let t = ContinuousClock().now
        store.apply([.support(.manifoldPressure, .supported), .support(.barometricPressure, .supported),
                     .sample(sample(.barometricPressure, 83, at: t)), .sample(sample(.manifoldPressure, 100, at: t))])
        #expect(store.channel(.boost)?.latest?.value == 17)
        // Re-discovery on a new link: BARO not reported.
        store.apply([.support(.barometricPressure, .unsupported),
                     .sample(sample(.manifoldPressure, 150, at: t + .seconds(60)))])
        let boost = store.channel(.boost)!
        #expect(boost.latest?.value == 17) // no new boost from the stale BARO
        if case .unavailable = boost.support {} else { Issue.record("boost should be unavailable, is \(boost.support)") }
    }

    @Test func rateAfterStaleGapMeasuresRealSamplesOnly() {
        let store = TelemetryStore()
        let t = ContinuousClock().now
        for i in 0..<10 { store.apply([.sample(sample(.engineRPM, 750, at: t + .milliseconds(100 * i)))]) }
        store.sweepStaleness(now: t + .seconds(5))
        for i in 0..<3 { store.apply([.sample(sample(.engineRPM, 750, at: t + .seconds(6) + .milliseconds(100 * i)))]) }
        let hz = store.channel(.engineRPM)!.observedRateHz!
        #expect(abs(hz - 10) < 0.01)
    }
}

@Suite("Regression: fix verification")
struct FixVerificationRegressionTests {
    /// A link drop during the post-probe quiet wait must surface as a link
    /// failure, not let the next command be written to a closed transport.
    @Test func linkLossDuringResyncIsReportedNotSwallowed() async throws {
        let t = ScriptedTransport { cmd in
            switch cmd {
            case "ATI": return .text("ELM327 v1.5\r\r>", after: .milliseconds(20))
            case "0100": return .text("41 00 BE 3F A8 13\r\r>", after: .milliseconds(10))
            default: return .silence
            }
        }
        var timing = ELM327Session.Timing()
        timing.defaultTimeout = .milliseconds(200)
        timing.latePromptGrace = .milliseconds(300)
        timing.resyncTimeout = .milliseconds(300)
        let s = ELM327Session(transport: t, log: CommLog(), timing: timing)
        await s.start(consuming: try await t.open(log: s.log))
        _ = try await s.execute("0100")
        await #expect(throws: ELMSessionError.timedOut(command: "010D")) { try await s.execute("010D") }
        let start = ContinuousClock().now
        Task {
            // grace (300) + probe reply (~20) puts us inside the quiet wait.
            try? await ContinuousClock().sleep(until: start + .milliseconds(420))
            t.disconnect()
        }
        await #expect(throws: ELMSessionError.self) { try await s.execute("010C") }
        #expect(t.writtenCommands == ["0100", "010D", "ATI"]) // 010C never written to the dead link
        #expect(await s.isClosed)
    }
}
