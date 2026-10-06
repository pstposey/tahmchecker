import Foundation

/// What we learned about the adapter and vehicle link.
public struct AdapterInfo: Sendable, Equatable {
    /// Text printed after ATZ (e.g. "ELM327 v1.5").
    public var resetBanner: String?
    /// Version the adapter *claims*; clones may report any version.
    public var reportedVersion: String?
    public var identification: String?
    public var deviceDescription: String?
    /// Supply voltage measured by the adapter (OBD pin 16), via ATRV.
    public var adapterVoltage: String?
    public var obdProtocol: OBDProtocol?
    public var protocolAutoDetected = false
    public var protocolDescription: String?
    /// ECUs that answered 01 00.
    public var responders: [ECUAddress] = []
    /// Headers are always on in Redline's init (ATH1).
    public var headersOn = true
    /// Physical request ID set with ATSH, if physical addressing is active.
    public var physicalRequestHeader: String?
    /// Protocol setting the adapter reported before Redline changed anything.
    public var storedProtocolBeforeInit: String?
    /// Commands this session sent that change PERSISTENT adapter settings
    /// (only ever `ATSP0`, and only if the adapter wasn't already automatic).
    /// None of them affects the vehicle.
    public var persistentAdapterWrites: [String] = []

    public init() {}
}

/// Experimental request optimizations. Both default OFF until measured on
/// the real adapter + vehicle (see docs/POLLING.md).
public struct ELMOptions: Sendable, Codable, Equatable {
    /// After discovery, if the protocol is 11-bit CAN and the engine ECU
    /// answered on 0x7E8, address it physically (ATSH 7E0) instead of the
    /// functional broadcast 0x7DF, so only that ECU answers.
    public var physicalAddressing = false
    /// Append the expected number of responses ("010C1") so the ELM327
    /// returns as soon as that many replies arrive instead of waiting for its
    /// response timeout (ELM327 v1.3+ feature; clones may not implement it).
    /// Applied only when exactly one ECU can answer. Disabled automatically
    /// if the adapter rejects it with "?".
    public var responseCountHint = false

    public init(physicalAddressing: Bool = false, responseCountHint: Bool = false) {
        self.physicalAddressing = physicalAddressing
        self.responseCountHint = responseCountHint
    }
}

public enum ELMInitError: Error, Sendable, Equatable, CustomStringConvertible {
    case commandRejected(command: String, response: String)
    case noBanner(String)

    public var description: String {
        switch self {
        case .commandRejected(let c, let r): return "Adapter rejected \(c): \(r)"
        case .noBanner(let r): return "ATZ produced no identification banner: \(r)"
        }
    }
}

/// The adapter initialization sequence and vehicle discovery.
///
/// Every command is listed with its reason. This is NOT a copied internet
/// sequence; each step exists because the parser or the measurements need
/// it. See docs/OBD.md for the rationale and what is still unverified on
/// the Vgate iCar Pro 2S.
public struct ELMInitializer: Sendable {
    public struct Step: Sendable {
        public enum Expectation: Sendable {
            /// Must reply OK.
            case ok
            /// Any reply; failure is logged but not fatal.
            case informational
            /// Reset: must produce a text banner.
            case banner
        }

        public let command: String
        public let purpose: String
        public let timeout: Duration
        public let expectation: Expectation
    }

    public static let adapterSteps: [Step] = [
        Step(command: "ATZ", purpose: "Full reset to known defaults; prints the version banner",
             timeout: .seconds(5), expectation: .banner),
        Step(command: "ATE0", purpose: "Echo off — the adapter stops repeating each command back",
             timeout: .seconds(2), expectation: .ok),
        Step(command: "ATL0", purpose: "Linefeeds off — lines end with CR only",
             timeout: .seconds(2), expectation: .ok),
        Step(command: "ATS1", purpose: "Spaces on — keeps 11-bit vs 29-bit CAN headers unambiguous to parse",
             timeout: .seconds(2), expectation: .ok),
        Step(command: "ATH1", purpose: "Headers on — identify which ECU answered (several can)",
             timeout: .seconds(2), expectation: .ok),
        Step(command: "ATI", purpose: "Identification string (informational)",
             timeout: .seconds(2), expectation: .informational),
        Step(command: "AT@1", purpose: "Device description (informational)",
             timeout: .seconds(2), expectation: .informational),
        Step(command: "ATRV", purpose: "Adapter-measured supply voltage (informational)",
             timeout: .seconds(2), expectation: .informational),
    ]

    public enum VehicleLink: Sendable, Equatable {
        case connected
        case unavailable(String)
    }

    public init() {}

    public func initializeAdapter(_ session: ELM327Session) async throws -> AdapterInfo {
        var info = AdapterInfo()
        let log = session.log
        log.info("Initializing adapter")
        for step in Self.adapterSteps {
            let ex = try await session.execute(step.command, timeout: step.timeout)
            let r = ex.response
            switch step.expectation {
            case .banner:
                guard let banner = r.firstTextLine ?? r.lines.first, !r.isUnknownCommand else {
                    throw ELMInitError.noBanner(r.raw)
                }
                info.resetBanner = banner
                info.reportedVersion = ELMResponse.elmVersion(fromBanner: banner)
            case .ok:
                guard r.isOK else {
                    throw ELMInitError.commandRejected(command: step.command, response: r.lines.joined(separator: " "))
                }
            case .informational:
                let text = r.isUnknownCommand ? nil : r.lines.joined(separator: " ")
                switch step.command {
                case "ATI": info.identification = text
                case "AT@1": info.deviceDescription = text
                case "ATRV": info.adapterVoltage = text
                default: break
                }
            }
        }
        try await ensureAutomaticProtocol(session, info: &info)
        log.info("Adapter: \(info.resetBanner ?? "?") — reports v\(info.reportedVersion ?? "?")")
        return info
    }

    /// `AT SP 0` selects automatic protocol search, but AT SP also STORES the
    /// protocol as the adapter's power-on default (an adapter EEPROM setting;
    /// it never reaches the vehicle). To avoid touching the adapter's stored
    /// configuration, Redline first reads the current setting (`AT DPN`) and
    /// sends `AT SP 0` only when the adapter is not already automatic.
    func ensureAutomaticProtocol(_ session: ELM327Session, info: inout AdapterInfo) async throws {
        let log = session.log
        let dpn = try await session.execute("ATDPN")
        let current = dpn.response.lines.first
        info.storedProtocolBeforeInit = current
        if let current, let parsed = OBDProtocol.parseDPN(current), parsed.proto == .automatic || parsed.automatic {
            log.info("Adapter protocol already automatic (\(current)); ATSP0 not needed — no adapter settings stored")
            return
        }
        log.warning("Adapter protocol setting is \(current ?? "unknown"), not automatic. Sending ATSP0, which stores 'automatic' as the ADAPTER's default (adapter setting only; nothing is sent to the vehicle)")
        let ex = try await session.execute("ATSP0")
        guard ex.response.isOK else {
            throw ELMInitError.commandRejected(command: "ATSP0", response: ex.response.lines.joined(separator: " "))
        }
        info.persistentAdapterWrites.append("ATSP0")
    }

    /// Sends 01 00. The first request after ATSP0 triggers protocol search,
    /// which can take several seconds ("SEARCHING...").
    public func connectToVehicle(_ session: ELM327Session, info: inout AdapterInfo, support: inout PIDSupportMap) async throws -> VehicleLink {
        let ex = try await session.execute("0100", timeout: .seconds(12))
        let r = ex.response
        let parsed = OBDFrameParser.parse(lines: r.hexLines, headersOn: info.headersOn, protocol: info.obdProtocol)
        let key = PIDKey(mode: 0x01, pid: 0x00)
        let payloads = OBDResponseDecoder.positivePayloads(for: key, in: parsed.messages)
        guard !payloads.isEmpty else {
            let why = r.messages.first?.rawValue ?? (parsed.issues.first ?? "no response")
            session.log.warning("Vehicle not responding to 0100: \(why)")
            return .unavailable(why)
        }
        for p in payloads {
            support.record(base: 0x00, bitmask: Array(p.data.prefix(4)), from: p.ecu)
        }
        info.responders = support.respondingECUs

        // Protocol actually in use.
        if let dpn = try? await session.execute("ATDPN"), let line = dpn.response.lines.first,
           let parsedDPN = OBDProtocol.parseDPN(line) {
            info.obdProtocol = parsedDPN.proto
            info.protocolAutoDetected = parsedDPN.automatic
        }
        if let dp = try? await session.execute("ATDP") {
            info.protocolDescription = dp.response.lines.first
        }
        session.log.info("Vehicle responded. Protocol: \(info.obdProtocol?.displayName ?? "?"); ECUs: \(info.responders.map(\.description).joined(separator: ", "))")
        return .connected
    }

    /// Queries the remaining "PIDs supported" ranges (01 20, 01 40, …) as
    /// advertised by the ECUs.
    public func discoverSupport(_ session: ELM327Session, info: AdapterInfo, support: inout PIDSupportMap) async throws {
        while let base = support.nextRangeToQuery() {
            let key = PIDKey(mode: 0x01, pid: base)
            let ex = try await session.execute(key.requestCommand, timeout: .seconds(3))
            let parsed = OBDFrameParser.parse(lines: ex.response.hexLines, headersOn: info.headersOn, protocol: info.obdProtocol)
            let payloads = OBDResponseDecoder.positivePayloads(for: key, in: parsed.messages)
            support.markQueried(base: base)
            for p in payloads {
                support.record(base: base, bitmask: Array(p.data.prefix(4)), from: p.ecu)
            }
        }
        let pids = support.allSupported.sorted().map(Hex.byteString).joined(separator: " ")
        session.log.info("Supported service 01 PIDs: \(pids)")
    }

    /// Applies `ELMOptions` that change addressing. Returns the effective
    /// options (physical addressing is skipped when its preconditions fail).
    public func applyRequestOptions(_ session: ELM327Session, options: ELMOptions, info: inout AdapterInfo) async throws -> ELMOptions {
        var effective = options
        info.physicalRequestHeader = nil
        if options.physicalAddressing {
            let engineECU = ECUAddress.can11(0x7E8)
            if info.obdProtocol?.canIDBits == 11, info.responders.contains(engineECU),
               let request = engineECU.physicalRequestID {
                let header = String(format: "%03X", request)
                let ex = try await session.execute("ATSH\(header)")
                if ex.response.isOK {
                    info.physicalRequestHeader = header
                    session.log.info("Physical addressing enabled (ATSH\(header))")
                } else {
                    effective.physicalAddressing = false
                    session.log.warning("ATSH\(header) rejected; staying with functional addressing")
                }
            } else {
                effective.physicalAddressing = false
                session.log.info("Physical addressing skipped: needs 11-bit CAN with an ECU at 7E8")
            }
        }
        return effective
    }
}
