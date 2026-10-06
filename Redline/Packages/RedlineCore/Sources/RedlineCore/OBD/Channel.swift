/// Stable identifier for a telemetry channel (ECU-reported or calculated).
/// String-backed so user-defined channels can be added later without
/// touching an enum.
public struct ChannelID: RawRepresentable, Hashable, Sendable, Codable, Comparable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    public static func < (a: ChannelID, b: ChannelID) -> Bool { a.rawValue < b.rawValue }
}

/// Physical quantity of a channel. Every value inside Redline is stored in
/// the quantity's canonical *base unit*; conversion to display units happens
/// only in `MeasurementPresenter`.
public enum Quantity: String, Sendable, Codable, CaseIterable {
    case pressure        // kPa
    case temperature     // °C
    case speed           // km/h
    case rotationalSpeed // rpm
    case percent         // %
    case voltage         // V
    case angle           // degrees
    case duration        // s
    case ratio           // dimensionless (equivalence ratio λ)
    case massFlow        // g/s
    case volumeFlow      // L/h
    case distance        // km

    public var baseUnitSymbol: String {
        switch self {
        case .pressure: return "kPa"
        case .temperature: return "°C"
        case .speed: return "km/h"
        case .rotationalSpeed: return "rpm"
        case .percent: return "%"
        case .voltage: return "V"
        case .angle: return "°"
        case .duration: return "s"
        case .ratio: return "λ"
        case .massFlow: return "g/s"
        case .volumeFlow: return "L/h"
        case .distance: return "km"
        }
    }
}

/// Provenance of a value. Every displayed number has exactly one.
public enum ValueSource: String, Sendable, Codable {
    /// Decoded directly from an ECU response.
    case ecuReported = "ECU_REPORTED"
    /// Deterministically derived from ECU-reported values (e.g. boost).
    case calculated = "CALCULATED"
    /// Derived using assumptions/models; never presented as measured.
    case estimated = "ESTIMATED"
    case unavailable = "UNAVAILABLE"
}

/// Polling priority. Targets are goals, not promises: the scheduler never
/// fabricates samples to meet them, and actual rates are measured.
public enum PollingClass: String, Sendable, Codable, CaseIterable, Comparable {
    case fast
    case medium
    case slow

    /// Desired interval between requests for one channel.
    public var targetInterval: Duration {
        switch self {
        case .fast: return .milliseconds(100)   // 10 Hz goal
        case .medium: return .milliseconds(333) // ~3 Hz
        case .slow: return .seconds(2)          // 0.5 Hz
        }
    }

    /// Age after which a value is shown as stale.
    public var staleAfter: Duration {
        switch self {
        case .fast: return .seconds(2)
        case .medium: return .seconds(3)
        case .slow: return .seconds(10)
        }
    }

    var rank: Int {
        switch self {
        case .fast: return 0
        case .medium: return 1
        case .slow: return 2
        }
    }

    public static func < (a: PollingClass, b: PollingClass) -> Bool { a.rank < b.rank }
}

public enum ChannelCategory: String, Sendable, Codable {
    case engine
    case airPath
    case fuel
    case temperature
    case electrical
    case vehicle
    case emissions
}

/// Which extreme a channel's "peak" tracks.
public enum PeakPolicy: String, Sendable, Codable {
    case none
    case maximum
    /// Only values > 0 count (boost: vacuum never becomes "peak boost").
    case maximumPositive
    case minimum
}

/// Static description of a channel, independent of where its values come from.
public struct ChannelDescriptor: Sendable, Identifiable, Equatable {
    public let id: ChannelID
    public let name: String
    public let shortName: String
    public let quantity: Quantity
    public let source: ValueSource
    public let category: ChannelCategory
    public let pollingClass: PollingClass
    /// Gross decode-sanity bounds in base units — NOT mechanical limits or
    /// warning thresholds. Values outside are flagged invalid and logged,
    /// never clamped. nil = any encodable value is plausible.
    public let plausibleRange: ClosedRange<Double>?
    public let peakPolicy: PeakPolicy
    /// Fixed display precision, for quantities whose resolution does not
    /// depend on the display unit (rpm, %, λ). nil = unit-dependent default.
    public let fractionDigits: Int?
    /// Formula / provenance documentation shown in the debug console.
    public let notes: String

    public init(
        id: ChannelID,
        name: String,
        shortName: String,
        quantity: Quantity,
        source: ValueSource = .ecuReported,
        category: ChannelCategory,
        pollingClass: PollingClass,
        plausibleRange: ClosedRange<Double>? = nil,
        peakPolicy: PeakPolicy = .none,
        fractionDigits: Int? = nil,
        notes: String
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.quantity = quantity
        self.source = source
        self.category = category
        self.pollingClass = pollingClass
        self.plausibleRange = plausibleRange
        self.peakPolicy = peakPolicy
        self.fractionDigits = fractionDigits
        self.notes = notes
    }

    public var staleAfter: Duration { pollingClass.staleAfter }

    public func isPlausible(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        return plausibleRange?.contains(value) ?? true
    }
}
