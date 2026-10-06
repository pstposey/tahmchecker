import Foundation

/// Runs the request loop against an initialized session. Lives off the main
/// actor so UI work can never delay a request; results are handed to the
/// store through an ordered stream.
public actor PollingWorker {
    public enum StopReason: Sendable, Equatable {
        case cancelled
        /// Many consecutive "no vehicle response" answers and no recent
        /// success (ignition off, ECU asleep).
        case vehicleUnresponsive
    }

    public struct Context: Sendable {
        public var info: AdapterInfo
        public var support: PIDSupportMap
        public var options: ELMOptions

        public init(info: AdapterInfo, support: PIDSupportMap, options: ELMOptions) {
            self.info = info
            self.support = support
            self.options = options
        }
    }

    private let session: ELM327Session
    private let monitor: PerformanceMonitor
    /// Reports automatic option fallbacks (e.g. the adapter rejected the
    /// response-count hint) so the engine's effective options stay truthful.
    private let onOptionsChanged: (@Sendable (ELMOptions) -> Void)?
    private var context: Context
    private var scheduler = PollScheduler()
    private var definitions: [PIDKey: PIDDefinition] = [:]
    private var paused = false
    private let clock = ContinuousClock()

    /// Per-request timeout. The ELM327's own response timeout (AT ST) is far
    /// shorter, so a normal "no answer" comes back as NO DATA well before this.
    public var requestTimeout: Duration = .milliseconds(1_000)
    private let vehicleLossFailures = 12
    private let vehicleLossQuietPeriod: Duration = .seconds(3)
    private let adapterLossTimeouts = 4

    public init(session: ELM327Session, monitor: PerformanceMonitor, context: Context,
                onOptionsChanged: (@Sendable (ELMOptions) -> Void)? = nil) {
        self.session = session
        self.monitor = monitor
        self.context = context
        self.onOptionsChanged = onOptionsChanged
    }

    /// Sets which PIDs are polled. Returns the channels actually polled
    /// (requested ∩ supported, respecting physical addressing).
    @discardableResult
    public func setPolled(_ defs: [PIDDefinition], intervalOverrides: [ChannelID: Duration] = [:]) -> Set<ChannelID> {
        let usable = defs.filter { isPollable($0) }
        definitions = Dictionary(uniqueKeysWithValues: usable.map { ($0.key, $0) })
        scheduler.setEntries(usable.map { ($0.key, $0.channel.pollingClass, intervalOverrides[$0.id]) })
        return Set(usable.map(\.id))
    }

    public func setPaused(_ value: Bool) {
        paused = value
    }

    func isPollable(_ def: PIDDefinition) -> Bool {
        guard def.mode == 0x01 else { return false }
        if context.info.physicalRequestHeader != nil {
            return context.support.byECU[.can11(0x7E8)]?.contains(def.pid) ?? false
        }
        return context.support.isSupported(def.pid)
    }

    /// Runs until cancelled, the vehicle stops answering, or the session
    /// fails (thrown).
    public func run(output: AsyncStream<[TelemetryUpdate]>.Continuation) async throws -> StopReason {
        var consecutiveVehicleFailures = 0
        var consecutiveTimeouts = 0
        var lastSuccessAt = clock.now

        while !Task.isCancelled {
            if paused {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            switch scheduler.next(now: clock.now) {
            case .nothingToPoll:
                try? await Task.sleep(for: .milliseconds(250))
                continue
            case .idle(let until):
                // Bounded so changes to the polled set take effect promptly.
                let cap = clock.now + .milliseconds(250)
                try? await clock.sleep(until: min(until, cap))
                continue
            case .poll(let key):
                guard let def = definitions[key] else { continue }
                let command = requestCommand(for: def)
                let requestedAt = clock.now
                scheduler.markRequested(key, at: requestedAt)
                monitor.setQueueDepth(await session.queueDepth)

                let exchange: ELMExchange
                do {
                    exchange = try await session.execute(command, timeout: requestTimeout)
                    consecutiveTimeouts = 0
                } catch ELMSessionError.timedOut {
                    consecutiveTimeouts += 1
                    let now = clock.now
                    monitor.record(ExchangeRecord(command: command, sentAt: requestedAt, firstByteAt: nil,
                                                  completedAt: now, decodedAt: nil, outcome: .timeout))
                    scheduler.markResult(key, success: false, at: now)
                    if consecutiveTimeouts >= adapterLossTimeouts { throw ELMSessionError.adapterUnresponsive }
                    continue
                } catch ELMSessionError.cancelled {
                    return .cancelled
                }

                let outcome = OBDResponseDecoder.decode(
                    def, response: exchange.response, headersOn: context.info.headersOn,
                    protocol: context.info.obdProtocol, preferredECUs: context.support.ecus(supporting: def.pid)
                )
                let decodedAt = clock.now
                let timing = SampleTiming(requestedAt: exchange.sentAt, receivedAt: exchange.completedAt, decodedAt: decodedAt)

                switch outcome {
                case .value(let value, let raw, let ecu, let plausible):
                    consecutiveVehicleFailures = 0
                    lastSuccessAt = decodedAt
                    let wasSuspended = scheduler.entries[key]?.consecutiveFailures ?? 0 >= scheduler.suspendAfterFailures
                    scheduler.markResult(key, success: true, at: decodedAt)
                    monitor.record(record(exchange, decodedAt: decodedAt, .success))
                    var updates: [TelemetryUpdate] = []
                    if wasSuspended { updates.append(.support(def.id, .supported)) }
                    updates.append(.sample(TelemetrySample(
                        channel: def.id, value: value, source: .ecuReported, isValid: plausible, raw: raw, ecu: ecu,
                        timing: timing, wallClock: exchange.wallClock
                    )))
                    if !plausible {
                        session.log.warning("Implausible \(def.channel.shortName) = \(value) from raw \(Hex.string(raw)); sample marked invalid")
                    }
                    output.yield(updates)

                case .message(let message):
                    if message == .unknownCommand, context.options.responseCountHint, command != key.requestCommand {
                        context.options.responseCountHint = false
                        onOptionsChanged?(context.options)
                        session.log.warning("Adapter rejected response-count suffix (\(command)); disabled for this session")
                        scheduler.markResult(key, success: true, at: decodedAt) // not the PID's fault
                        continue
                    }
                    if message.indicatesNoVehicleResponse { consecutiveVehicleFailures += 1 }
                    monitor.record(record(exchange, decodedAt: decodedAt, .noData(message.rawValue)))
                    failed(def, at: decodedAt, reason: message.rawValue, output: output)

                case .negativeResponse(let nrc, _):
                    monitor.record(record(exchange, decodedAt: decodedAt, .noData("NRC \(Hex.byteString(nrc))")))
                    failed(def, at: decodedAt, reason: "Negative response \(Hex.byteString(nrc))", output: output)

                case .malformed(let why):
                    session.log.warning("Malformed response to \(command): \(why)")
                    monitor.record(record(exchange, decodedAt: decodedAt, .malformed(why)))
                    failed(def, at: decodedAt, reason: "Malformed response", output: output)
                }

                if consecutiveVehicleFailures >= vehicleLossFailures, decodedAt - lastSuccessAt >= vehicleLossQuietPeriod {
                    session.log.warning("No vehicle response for \(consecutiveVehicleFailures) requests; treating vehicle as unavailable")
                    return .vehicleUnresponsive
                }
            }
        }
        return .cancelled
    }

    private func failed(_ def: PIDDefinition, at time: MonotonicInstant, reason: String,
                        output: AsyncStream<[TelemetryUpdate]>.Continuation) {
        if scheduler.markResult(def.key, success: false, at: time) {
            output.yield([.support(def.id, .unavailable("\(reason) — retrying"))])
        }
    }

    private func record(_ ex: ELMExchange, decodedAt: MonotonicInstant, _ outcome: ExchangeRecord.Outcome) -> ExchangeRecord {
        ExchangeRecord(command: ex.command, sentAt: ex.sentAt, firstByteAt: ex.firstByteAt,
                       completedAt: ex.completedAt, decodedAt: decodedAt, outcome: outcome)
    }

    /// "010C", or "010C1" when the response-count hint applies.
    func requestCommand(for def: PIDDefinition) -> String {
        let base = def.key.requestCommand
        guard context.options.responseCountHint else { return base }
        let singleResponder = context.info.physicalRequestHeader != nil
            || context.support.ecus(supporting: def.pid).count == 1
        return singleResponder ? base + "1" : base
    }
}
