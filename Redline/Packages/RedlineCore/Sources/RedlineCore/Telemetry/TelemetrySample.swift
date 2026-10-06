import Foundation

/// Timestamps for one sample, all from the monotonic clock.
public struct SampleTiming: Sendable, Equatable {
    /// When the request that produced the sample was handed to the transport.
    public let requestedAt: MonotonicInstant?
    /// When the response's final chunk (with the `>` prompt) was received.
    public let receivedAt: MonotonicInstant
    /// When decoding finished.
    public let decodedAt: MonotonicInstant

    public init(requestedAt: MonotonicInstant?, receivedAt: MonotonicInstant, decodedAt: MonotonicInstant) {
        self.requestedAt = requestedAt
        self.receivedAt = receivedAt
        self.decodedAt = decodedAt
    }
}

/// One real measurement (or a value calculated from real measurements).
/// Samples are never interpolated or synthesized to raise apparent rate.
public struct TelemetrySample: Sendable, Equatable {
    public let channel: ChannelID
    /// Value in the channel quantity's base unit.
    public let value: Double
    public let source: ValueSource
    /// False when the decoded value failed the decode-sanity check. Invalid
    /// samples are kept for diagnostics but never displayed as current.
    public let isValid: Bool
    /// Raw data bytes the value was decoded from (empty for calculated).
    public let raw: [UInt8]
    public let ecu: ECUAddress?
    public let timing: SampleTiming
    public let wallClock: Date
    /// For calculated values: the inputs used.
    public let derivation: String?

    public init(
        channel: ChannelID, value: Double, source: ValueSource, isValid: Bool = true, raw: [UInt8] = [],
        ecu: ECUAddress? = nil, timing: SampleTiming, wallClock: Date = Date(), derivation: String? = nil
    ) {
        self.channel = channel
        self.value = value
        self.source = source
        self.isValid = isValid
        self.raw = raw
        self.ecu = ecu
        self.timing = timing
        self.wallClock = wallClock
        self.derivation = derivation
    }
}

public enum SupportState: Sendable, Equatable {
    /// Discovery has not run (or not for this channel yet).
    case unknown
    case supported
    /// The vehicle does not report this parameter.
    case unsupported
    /// Supported (or derivable) but currently not producing data.
    case unavailable(String)
}

/// Messages from the telemetry engine to the store.
public enum TelemetryUpdate: Sendable, Equatable {
    case sample(TelemetrySample)
    case support(ChannelID, SupportState)
}
