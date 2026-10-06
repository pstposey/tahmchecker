import Foundation

/// An in-process ELM327 emulator backed by `SimulatedVehicle`.
///
/// It speaks the same byte protocol as a real adapter (echo, headers,
/// spaces, prompt, SEARCHING..., NO DATA, multi-ECU replies, chunked
/// delivery), so the *entire* real pipeline — framer, parser, session,
/// scheduler, decoder, store — runs unchanged in simulation. Only the
/// transport identity (`.simulated`) differs, and the UI labels it.
///
/// Emulated ECUs: an engine ECU at 7E8 answering the simulated PIDs, and a
/// transmission ECU at 7E9 that answers only "PIDs supported" requests (to
/// exercise multi-ECU parsing). Mode 01 only; other services → NO DATA.
public final class SimulatedELM327Transport: OBDTransport, @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Simulated adapter + ECU response time.
        public var latency: ClosedRange<Double> = 0.018...0.035
        /// BLE-like notification size; responses are split into chunks.
        public var chunkSize = 20
        public var version = "v1.5"
        /// Whether the emulated adapter accepts the trailing response-count
        /// digit ("010C1"). Real clones may not; set false to test the fallback.
        public var supportsResponseCountHint = true
        public init() {}
    }

    public let identity: TransportIdentity
    public let vehicle: SimulatedVehicle
    private let config: Configuration

    private struct ELMState {
        var echo = true
        var linefeeds = false
        var spaces = true
        var headers = false
        var protocolSearched = false
        var physicalHeader: UInt32?
        var lastCommand = ""
        var inputBuffer = ""
        var continuation: AsyncStream<TransportEvent>.Continuation?
        var isOpen = false
        var rng = SplitMix64(seed: 0xE1A3)
    }

    private let state = Locked(ELMState())
    private let clock = ContinuousClock()

    /// PIDs the simulated engine ECU reports as supported.
    public let enginePIDs: Set<UInt8>

    public init(vehicle: SimulatedVehicle = SimulatedVehicle(), configuration: Configuration = Configuration()) {
        self.vehicle = vehicle
        self.config = configuration
        self.identity = TransportIdentity(kind: .simulated, name: "Redline Simulator", identifier: "simulator")
        let probe = vehicle.snapshot()
        self.enginePIDs = Set(StandardPIDs.all.filter { vehicle.value(for: $0.id, in: probe) != nil }.map(\.pid))
    }

    // MARK: OBDTransport

    public func open(log: CommLog) async throws -> AsyncStream<TransportEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        state.withLock { s in
            s.continuation?.finish()
            s = ELMState()
            s.continuation = continuation
            s.isOpen = true
        }
        log.info("SIMULATION: in-process ELM327 emulator (no hardware)")
        return stream
    }

    public func write(_ data: Data) async throws {
        let commands: [String] = try state.withLock { s in
            guard s.isOpen else { throw TransportError.notOpen }
            s.inputBuffer += String(decoding: data, as: UTF8.self)
            var complete: [String] = []
            while let cr = s.inputBuffer.firstIndex(of: "\r") {
                complete.append(String(s.inputBuffer[..<cr]))
                s.inputBuffer = String(s.inputBuffer[s.inputBuffer.index(after: cr)...])
            }
            return complete
        }
        for command in commands {
            let (reply, delay) = respond(to: command)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.deliver(reply)
            }
        }
    }

    public func close() async {
        state.withLock { s in
            s.isOpen = false
            s.continuation?.yield(.closed(nil))
            s.continuation?.finish()
            s.continuation = nil
        }
    }

    public func linkDetails() async -> TransportLinkDetails {
        TransportLinkDetails(items: [
            .init("Transport", "Simulated ELM327 (in-process, no hardware)"),
            .init("Simulated latency", String(format: "%.0f–%.0f ms",
                                              config.latency.lowerBound * 1_000, config.latency.upperBound * 1_000)),
            .init("Scenario", vehicle.scenario.title),
        ])
    }

    // MARK: Emulation

    private func deliver(_ text: String) {
        let bytes = Array(text.utf8)
        state.withLock { s in
            guard s.isOpen, let c = s.continuation else { return }
            var i = 0
            while i < bytes.count {
                let end = min(i + config.chunkSize, bytes.count)
                c.yield(.received(Data(bytes[i..<end]), at: clock.now))
                i = end
            }
        }
    }

    /// Returns the full reply text (including the final prompt) and its delay.
    func respond(to rawCommand: String) -> (String, Double) {
        state.withLock { s in
            var command = rawCommand.uppercased().filter { !$0.isWhitespace }
            if command.isEmpty { command = s.lastCommand } // bare CR repeats
            s.lastCommand = command
            let delay = config.latency.lowerBound
                + s.rng.nextUnit() * (config.latency.upperBound - config.latency.lowerBound)

            let echo = s.echo ? rawCommand + "\r" : ""
            let lines: [String]
            var extraDelay = 0.0
            if command.hasPrefix("AT") {
                lines = handleAT(String(command.dropFirst(2)), &s)
                if command == "ATZ" { extraDelay = 0.5 }
            } else {
                var searchPrefix: [String] = []
                if !s.protocolSearched {
                    s.protocolSearched = true
                    searchPrefix = ["SEARCHING..."]
                    extraDelay = 0.8
                }
                lines = searchPrefix + handleOBD(command, s)
            }
            let eol = s.linefeeds ? "\r\n" : "\r"
            return (echo + lines.joined(separator: eol) + eol + eol + ">", delay + extraDelay)
        }
    }

    private func handleAT(_ body: String, _ s: inout ELMState) -> [String] {
        let banner = "ELM327 \(config.version)"
        switch body {
        case "Z":
            let keepContinuation = s.continuation
            let rng = s.rng
            s = ELMState()
            s.continuation = keepContinuation
            s.isOpen = true
            s.rng = rng
            return ["", banner]
        case "WS": return ["", banner]
        case "I": return [banner]
        case "@1": return ["REDLINE SIMULATED ADAPTER"]
        case "RV": return [String(format: "%.1fV", vehicle.snapshot().voltage)]
        case "E0": s.echo = false; return ["OK"]
        case "E1": s.echo = true; return ["OK"]
        case "L0": s.linefeeds = false; return ["OK"]
        case "L1": s.linefeeds = true; return ["OK"]
        case "S0": s.spaces = false; return ["OK"]
        case "S1": s.spaces = true; return ["OK"]
        case "H0": s.headers = false; return ["OK"]
        case "H1": s.headers = true; return ["OK"]
        case "DPN": return [s.protocolSearched ? "A6" : "0"]
        case "DP": return [s.protocolSearched ? "AUTO, ISO 15765-4 (CAN 11/500)" : "AUTO"]
        default:
            if body.hasPrefix("SP") || body.hasPrefix("TP") || body.hasPrefix("ST") || body.hasPrefix("AT") {
                return ["OK"]
            }
            if body.hasPrefix("SH"), let id = Hex.value(body.dropFirst(2)) {
                s.physicalHeader = id
                return ["OK"]
            }
            return ["?"]
        }
    }

    private func handleOBD(_ command: String, _ s: ELMState) -> [String] {
        // Optional trailing response-count digit.
        var hex = command
        if hex.count % 2 == 1 {
            guard config.supportsResponseCountHint else { return ["?"] }
            hex.removeLast()
        }
        guard let bytes = Hex.bytes(hex), bytes.count >= 2, bytes[0] == 0x01 else {
            return Hex.bytes(hex) == nil ? ["?"] : ["NO DATA"]
        }
        let pids = Array(bytes.dropFirst())
        let snapshot = vehicle.snapshot()
        let toTransmission = s.physicalHeader == nil || s.physicalHeader == 0x7E1
        let toEngine = s.physicalHeader == nil || s.physicalHeader == 0x7E0

        var replies: [(ecu: UInt32, payload: [UInt8])] = []
        if toEngine {
            var payload: [UInt8] = [0x41]
            for pid in pids {
                if let data = engineData(pid: pid, snapshot: snapshot) {
                    payload.append(pid)
                    payload.append(contentsOf: data)
                }
            }
            if payload.count > 1 { replies.append((0x7E8, payload)) }
        }
        if toTransmission, pids == [0x00] {
            // Transmission ECU answers only 01 00 (advertising PID 01), so
            // multi-ECU responses are exercised.
            replies.append((0x7E9, [0x41, 0x00, 0x80, 0x00, 0x00, 0x00]))
        }
        guard !replies.isEmpty else { return ["NO DATA"] }
        return replies.flatMap { format(ecu: $0.ecu, payload: $0.payload, s) }
    }

    private func engineData(pid: UInt8, snapshot: SimulatedVehicle.Snapshot) -> [UInt8]? {
        if pid % 0x20 == 0 {
            let mask = supportMask(base: pid)
            return mask == [0, 0, 0, 0] && pid != 0 ? nil : mask
        }
        guard enginePIDs.contains(pid), let def = StandardPIDs.byKey[PIDKey(mode: 0x01, pid: pid)],
              let value = vehicle.value(for: def.id, in: snapshot) else { return nil }
        return def.formula.encode(value, totalBytes: def.responseLength)
    }

    func supportMask(base: UInt8) -> [UInt8] {
        var mask: [UInt8] = [0, 0, 0, 0]
        let highest = enginePIDs.max() ?? 0
        for i in 0..<32 {
            let pid = Int(base) + i + 1
            let isNextRange = i == 31 && pid <= Int(highest)
            if (pid <= 0xFF && enginePIDs.contains(UInt8(pid))) || isNextRange {
                mask[i / 8] |= 0x80 >> UInt8(i % 8)
            }
        }
        return mask
    }

    /// Formats one ECU's message as ELM327 would display it.
    private func format(ecu: UInt32, payload: [UInt8], _ s: ELMState) -> [String] {
        let sep = s.spaces ? " " : ""
        func line(_ frame: [UInt8]) -> String {
            let body = Hex.string(frame, separator: sep)
            return s.headers ? String(format: "%03X", ecu) + sep + body : body
        }
        if payload.count <= 7 {
            return [line(s.headers ? [UInt8(payload.count)] + payload : payload)]
        }
        // ISO-TP multi-frame.
        if s.headers {
            var frames: [[UInt8]] = [[0x10 | UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload.prefix(6)]
            var rest = Array(payload.dropFirst(6))
            var seq: UInt8 = 1
            while !rest.isEmpty {
                frames.append([0x20 | seq] + rest.prefix(7))
                rest = Array(rest.dropFirst(7))
                seq = (seq + 1) & 0x0F
            }
            return frames.map(line)
        }
        var lines = [String(format: "%03X", payload.count)]
        var rest = payload
        var index = 0
        while !rest.isEmpty {
            lines.append("\(String(index, radix: 16, uppercase: true)):\(sep)" + Hex.string(rest.prefix(index == 0 ? 6 : 7), separator: sep))
            rest = Array(rest.dropFirst(index == 0 ? 6 : 7))
            index = (index + 1) % 16
        }
        return lines
    }
}
