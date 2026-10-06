/// Matches parsed ECU messages to a request and decodes values.
public enum OBDResponseDecoder {
    /// Result of decoding one single-PID request.
    public enum Outcome: Sendable, Equatable {
        /// A positive response decoded to a base-unit value.
        case value(Double, raw: [UInt8], ecu: ECUAddress?, plausible: Bool)
        /// The adapter or vehicle reported a status instead of data.
        case message(ELMMessage)
        /// ISO 14229 negative response (7F service NRC).
        case negativeResponse(nrc: UInt8, ecu: ECUAddress?)
        /// Data arrived but did not match the request or was too short.
        case malformed(String)
    }

    /// Data bytes following `[service + 0x40, pid]`, one entry per ECU that
    /// answered positively.
    public static func positivePayloads(for key: PIDKey, in messages: [ECUMessage]) -> [(ecu: ECUAddress?, data: [UInt8])] {
        messages.compactMap { m in
            guard m.payload.count >= 2, m.payload[0] == key.mode &+ 0x40, m.payload[1] == key.pid else { return nil }
            return (m.ecu, Array(m.payload.dropFirst(2)))
        }
    }

    public static func negativeResponse(for key: PIDKey, in messages: [ECUMessage]) -> (nrc: UInt8, ecu: ECUAddress?)? {
        for m in messages where m.payload.count >= 3 && m.payload[0] == 0x7F && m.payload[1] == key.mode {
            return (m.payload[2], m.ecu)
        }
        return nil
    }

    /// Decodes a single-PID response.
    /// - Parameter preferredECUs: when several ECUs answer, the first of
    ///   these that answered wins; otherwise the lowest address wins.
    public static func decode(
        _ definition: PIDDefinition,
        response: ELMResponse,
        headersOn: Bool,
        protocol proto: OBDProtocol?,
        preferredECUs: [ECUAddress] = []
    ) -> Outcome {
        let parsed = OBDFrameParser.parse(lines: response.hexLines, headersOn: headersOn, protocol: proto)
        let payloads = positivePayloads(for: definition.key, in: parsed.messages)

        guard !payloads.isEmpty else {
            if let nr = negativeResponse(for: definition.key, in: parsed.messages) {
                return .negativeResponse(nrc: nr.nrc, ecu: nr.ecu)
            }
            if let m = response.messages.first { return .message(m) }
            if !parsed.issues.isEmpty { return .malformed(parsed.issues.joined(separator: "; ")) }
            return .malformed("no response matching \(definition.key)")
        }

        let chosen = preferredECUs.lazy.compactMap { ecu in payloads.first { $0.ecu == ecu } }.first
            ?? payloads.min { ($0.ecu ?? PIDSupportMap.unknownECU) < ($1.ecu ?? PIDSupportMap.unknownECU) }!

        guard chosen.data.count >= definition.responseLength else {
            return .malformed("\(definition.key): expected \(definition.responseLength) data bytes, got \(chosen.data.count)")
        }
        let data = Array(chosen.data.prefix(definition.responseLength))
        guard let value = definition.formula.evaluate(data) else {
            return .malformed("\(definition.key): formula could not read \(Hex.string(data))")
        }
        return .value(value, raw: data, ecu: chosen.ecu, plausible: definition.channel.isPlausible(value))
    }
}
