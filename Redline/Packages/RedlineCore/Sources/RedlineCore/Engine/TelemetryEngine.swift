import Foundation
import Observation

/// Connection lifecycle as shown to the user.
public enum EngineState: Sendable, Equatable {
    case idle
    case connecting
    case initializingAdapter
    case searchingForVehicle
    /// Adapter fine, vehicle not answering (ignition off?). Retrying.
    case vehicleUnavailable(String)
    case discoveringPIDs
    case streaming
    case disconnected(String?)
    case reconnecting(attempt: Int)
    case failed(String)

    public var title: String {
        switch self {
        case .idle: return "Not connected"
        case .connecting: return "Connecting"
        case .initializingAdapter: return "Initializing adapter"
        case .searchingForVehicle: return "Contacting vehicle"
        case .vehicleUnavailable: return "Vehicle unavailable"
        case .discoveringPIDs: return "Detecting supported data"
        case .streaming: return "Connected"
        case .disconnected: return "Disconnected"
        case .reconnecting(let n): return "Reconnecting (attempt \(n))"
        case .failed: return "Error"
        }
    }

    public var detail: String? {
        switch self {
        case .vehicleUnavailable(let why): return why
        case .disconnected(let why): return why
        case .failed(let why): return why
        default: return nil
        }
    }

    public var isStreaming: Bool { self == .streaming }
}

/// Owns one telemetry source at a time (real adapter or simulator) and runs
/// its lifecycle. UI-facing state is main-actor; all adapter I/O happens in
/// `ELM327Session` / `PollingWorker` actors, so the UI never waits on OBD.
@MainActor
@Observable
public final class TelemetryEngine {
    public private(set) var state: EngineState = .idle {
        didSet {
            guard state != oldValue else { return }
            stateHistory.append(StateTransition(at: Date(), state: state))
            if stateHistory.count > Self.stateHistoryCapacity {
                stateHistory.removeFirst(stateHistory.count - Self.stateHistoryCapacity)
            }
        }
    }
    /// Recent connection-state changes, oldest first (debug report).
    @ObservationIgnored public private(set) var stateHistory: [StateTransition] = []
    static let stateHistoryCapacity = 100
    public private(set) var adapterInfo: AdapterInfo?
    public private(set) var support: PIDSupportMap?
    public private(set) var transportIdentity: TransportIdentity?
    public private(set) var linkDetails: TransportLinkDetails?
    /// Options in effect for the current session (after automatic fallbacks).
    public private(set) var effectiveOptions: ELMOptions?
    public private(set) var polledChannels: Set<ChannelID> = []
    public private(set) var isPaused = false
    /// True while `stop()` is tearing down the current source.
    public private(set) var isStopping = false

    /// Requested options; applied at the next (re)connection.
    public var options: ELMOptions
    public var autoReconnect = true
    public var pollingPreset: PollingPreset {
        didSet { if oldValue != pollingPreset { Task { await applyPollingSet() } } }
    }

    public let store: TelemetryStore
    public let log: CommLog
    public let monitor: PerformanceMonitor

    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var session: ELM327Session?
    @ObservationIgnored private var worker: PollingWorker?
    @ObservationIgnored private var transport: (any OBDTransport)?
    @ObservationIgnored private var stalenessTask: Task<Void, Never>?
    private let initRecorder = InitStepRecorder()
    /// Set when a connection reaches `.streaming`; resets the reconnect backoff.
    @ObservationIgnored private var reachedStreaming = false
    @ObservationIgnored private var retryRequested = false
    /// Consecutive `0100` probes the vehicle did not answer.
    @ObservationIgnored var unansweredVehicleProbes = 0

    public init(
        store: TelemetryStore? = nil,
        log: CommLog = CommLog(),
        monitor: PerformanceMonitor = PerformanceMonitor(),
        options: ELMOptions = ELMOptions(),
        pollingPreset: PollingPreset = .rpmAndBoost
    ) {
        self.store = store ?? TelemetryStore()
        self.log = log
        self.monitor = monitor
        self.options = options
        self.pollingPreset = pollingPreset
        self.store.onPublishLatency = { [monitor] latency in monitor.recordPublish(latency: latency) }
    }

    // MARK: Lifecycle

    /// Starts (or replaces) the telemetry source.
    public func start(transport: any OBDTransport) {
        let previous = connectionTask
        previous?.cancel()
        let previousTransport = self.transport
        self.transport = transport
        startStalenessSweep()
        connectionTask = Task { [weak self] in
            await previous?.value
            if let previousTransport, previousTransport !== transport { await previousTransport.close() }
            await self?.runConnectionLoop(transport)
        }
    }

    /// Stops polling and closes the link.
    ///
    /// The teardown is itself stored as `connectionTask`, so a `start()`
    /// issued while `stop()` is still waiting chains after it instead of
    /// racing it (and `stop()` never closes a transport started meanwhile).
    public func stop() async {
        isStopping = true
        defer { isStopping = false }
        let task = connectionTask
        task?.cancel()
        let session = self.session
        let transport = self.transport
        self.transport = nil
        let teardown = Task { @MainActor in
            await session?.close()
            await task?.value
            await transport?.close()
        }
        connectionTask = teardown
        await teardown.value
        guard connectionTask == teardown else { return } // a newer start() owns the engine now
        connectionTask = nil
        clearSessionMetadata()
        state = .idle
    }

    /// Pauses requests without dropping the link (e.g. app backgrounded).
    public func setPaused(_ paused: Bool) {
        isPaused = paused
        Task { await worker?.setPaused(paused) }
    }

    /// Sends a developer-console command through the same serialized session
    /// as the poller. Only read-only commands pass `CommandSafetyPolicy`.
    public func sendConsoleCommand(_ text: String) async -> String {
        switch CommandSafetyPolicy.evaluateConsoleCommand(text) {
        case .blocked(let why):
            log.warning("Console blocked: \(why)")
            return "BLOCKED: \(why)"
        case .allowed:
            break
        }
        guard let session else { return "No active session" }
        do {
            let ex = try await session.execute(CommandSafetyPolicy.normalize(text))
            return ex.response.lines.joined(separator: "\n") + String(format: "\n[%.1f ms]", ex.roundTrip.milliseconds)
        } catch {
            return "ERROR: \(error)"
        }
    }

    /// The initialization / vehicle-detection commands of the current link,
    /// including failed ones (debug report).
    public var initSteps: [InitStepRecord] { initRecorder.all }

    public func performanceSnapshot() -> PerformanceSnapshot {
        monitor.snapshot(now: ContinuousClock().now)
    }

    // MARK: Connection loop

    private func runConnectionLoop(_ transport: any OBDTransport) async {
        store.resetSession(sourceKind: transport.identity.kind)
        monitor.reset()
        clearSessionMetadata()
        transportIdentity = transport.identity
        unansweredVehicleProbes = 0 // each new connection starts at the short retry interval
        var attempt = 0
        while !Task.isCancelled {
            reachedStreaming = false
            let endReason = await runSingleConnection(transport)
            if Task.isCancelled { break }
            if reachedStreaming { attempt = 0 } // backoff restarts after a good session
            guard autoReconnect else {
                state = .disconnected(endReason)
                break
            }
            attempt += 1
            state = .reconnecting(attempt: attempt)
            log.info("Reconnecting in \(Self.backoff(attempt)) (\(endReason ?? "link closed"))")
            try? await interruptibleSleep(Self.backoff(attempt))
        }
        if Task.isCancelled { state = .idle }
    }

    static func backoff(_ attempt: Int) -> Duration {
        .seconds(min(15, 1 << min(attempt, 4)))
    }

    /// 3 s for the first five tries (~15 s), then 10 s, then 30 s.
    static func vehicleRetryDelay(_ unanswered: Int) -> Duration {
        switch unanswered {
        case ..<6: return .seconds(3)
        case 6..<12: return .seconds(10)
        default: return .seconds(30)
        }
    }

    /// Cuts the current reconnect / vehicle-retry wait short (e.g. the app
    /// returned to the foreground, or the user tapped Retry).
    public func retryNow() {
        switch state {
        case .reconnecting, .vehicleUnavailable, .failed, .disconnected:
            retryRequested = true
            unansweredVehicleProbes = 0 // an explicit retry starts the short cadence again
        default: break
        }
    }

    private func interruptibleSleep(_ duration: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + duration
        retryRequested = false
        while clock.now < deadline {
            if retryRequested {
                retryRequested = false
                log.info("Retrying now")
                return
            }
            try await Task.sleep(for: min(.milliseconds(200), deadline - clock.now))
        }
    }

    /// Clears everything learned from a previous link, so the debug screen and
    /// report never attribute one source's adapter/vehicle facts to another.
    private func clearSessionMetadata() {
        adapterInfo = nil
        support = nil
        effectiveOptions = nil
        linkDetails = nil
        polledChannels = []
        store.setPolledChannels([])
    }

    /// One link lifetime. Returns why it ended.
    private func runSingleConnection(_ transport: any OBDTransport) async -> String? {
        clearSessionMetadata()
        initRecorder.reset()
        state = .connecting
        log.info("Opening \(transport.identity.kind.rawValue) link to \(transport.identity.name)")
        let events: AsyncStream<TransportEvent>
        do {
            events = try await transport.open(log: log)
        } catch {
            let why = String(describing: error)
            log.error("Open failed: \(why)")
            state = .failed(why)
            return why
        }
        linkDetails = await transport.linkDetails()

        let session = ELM327Session(transport: transport, log: log)
        await session.start(consuming: events)
        self.session = session
        defer { self.session = nil }

        do {
            while !Task.isCancelled {
                let reason = try await runVehicleSession(session)
                if reason == .cancelled { break }
                // Vehicle went quiet: re-initialize the adapter and wait for it.
                state = .vehicleUnavailable("Vehicle stopped responding — waiting")
                try await Task.sleep(for: .seconds(2))
            }
            await session.close()
            return nil
        } catch {
            let why = (error as? ELMSessionError)?.description ?? String(describing: error)
            log.error("Session ended: \(why)")
            await session.close()
            if Task.isCancelled { return nil }
            state = .disconnected(why)
            return why
        }
    }

    private func runVehicleSession(_ session: ELM327Session) async throws -> PollingWorker.StopReason {
        support = nil
        effectiveOptions = nil
        polledChannels = []
        store.setPolledChannels([])
        state = .initializingAdapter
        let initializer = ELMInitializer(recorder: initRecorder)
        var info = try await initializer.initializeAdapter(session)
        adapterInfo = info

        var support = PIDSupportMap()
        while true {
            state = .searchingForVehicle
            switch try await initializer.connectToVehicle(session, info: &info, support: &support) {
            case .connected:
                break
            case .unavailable(let why):
                // Each unanswered 0100 can make the adapter run its protocol
                // search (initialization traffic on every OBD protocol), so
                // retries slow down the longer the vehicle stays silent.
                unansweredVehicleProbes += 1
                let wait = Self.vehicleRetryDelay(unansweredVehicleProbes)
                state = .vehicleUnavailable("\(why) — is the ignition on? Retrying in \(Int(wait.seconds)) s")
                try await interruptibleSleep(wait)
                if Task.isCancelled { return .cancelled }
                continue
            }
            break
        }

        unansweredVehicleProbes = 0
        state = .discoveringPIDs
        try await initializer.discoverSupport(session, info: info, support: &support)
        let effective = try await initializer.applyRequestOptions(session, options: options, info: &info)
        adapterInfo = info
        self.support = support
        effectiveOptions = effective
        publishSupport(support, info: info)

        let worker = PollingWorker(
            session: session, monitor: monitor,
            context: .init(info: info, support: support, options: effective),
            onOptionsChanged: { [weak self] changed in
                Task { @MainActor in self?.effectiveOptions = changed }
            }
        )
        self.worker = worker
        defer { self.worker = nil }
        await worker.setPaused(isPaused)
        await applyPollingSet()

        state = .streaming
        reachedStreaming = true
        let (stream, continuation) = AsyncStream.makeStream(of: [TelemetryUpdate].self,
                                                            bufferingPolicy: .bufferingNewest(512))
        let consumer = Task { @MainActor [store] in
            for await batch in stream { store.apply(batch) }
        }
        defer {
            continuation.finish()
            consumer.cancel()
        }
        return try await worker.run(output: continuation)
    }

    private func publishSupport(_ support: PIDSupportMap, info: AdapterInfo) {
        var updates: [TelemetryUpdate] = []
        for def in StandardPIDs.all where def.mode == 0x01 {
            let supported = info.physicalRequestHeader != nil
                ? (support.byECU[.can11(0x7E8)]?.contains(def.pid) ?? false)
                : support.isSupported(def.pid)
            if supported, !CommandSafetyPolicy.evaluateTransmission(def.key.requestCommand).isAllowed {
                updates.append(.support(def.id, .unavailable("Not requested: \"\(def.key.requestCommand)\" is refused by the read-only policy (unsafe if truncated)")))
                continue
            }
            updates.append(.support(def.id, supported ? .supported : .unsupported))
        }
        store.apply(updates)
    }

    private func applyPollingSet() async {
        guard let worker else {
            polledChannels = []
            store.setPolledChannels([])
            return
        }
        let polled = await worker.setPolled(pollingPreset.definitions)
        polledChannels = polled
        store.setPolledChannels(polled)
        log.info("Polling: \(polled.map(\.rawValue).sorted().joined(separator: ", "))")
    }

    private func startStalenessSweep() {
        guard stalenessTask == nil else { return }
        stalenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.store.sweepStaleness()
            }
        }
    }
}
