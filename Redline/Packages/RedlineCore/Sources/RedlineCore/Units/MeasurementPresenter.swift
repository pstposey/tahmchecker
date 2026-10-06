import Foundation

/// A value converted to the user's display unit, ready to render.
public struct DisplayValue: Sendable, Equatable {
    public let value: Double
    public let unitSymbol: String
    public let fractionDigits: Int

    /// Numeric text without the unit ("16.7", "-7.5", "1,726" is NOT used —
    /// no grouping separators on gauges; they hurt glanceability).
    public var text: String {
        // Avoid "-0.0".
        let rounded = (value * pow(10, Double(fractionDigits))).rounded() / pow(10, Double(fractionDigits))
        let v = rounded == 0 ? 0 : rounded
        return String(format: "%.\(fractionDigits)f", v)
    }
}

/// The single place where base-unit values become display values.
public struct MeasurementPresenter: Sendable, Equatable {
    public var preferences: UnitPreferences

    public init(preferences: UnitPreferences = .personalDefault) {
        self.preferences = preferences
    }

    public func display(_ baseValue: Double, for channel: ChannelDescriptor) -> DisplayValue {
        let converted = convert(baseValue, quantity: channel.quantity)
        return DisplayValue(
            value: converted.value,
            unitSymbol: converted.symbol,
            fractionDigits: channel.fractionDigits ?? defaultFractionDigits(channel.quantity)
        )
    }

    public func unitSymbol(for quantity: Quantity) -> String {
        convert(0, quantity: quantity).symbol
    }

    func convert(_ v: Double, quantity: Quantity) -> (value: Double, symbol: String) {
        switch quantity {
        case .pressure:
            return (UnitConversion.pressure(kilopascals: v, to: preferences.pressure), preferences.pressure.symbol)
        case .temperature:
            return (UnitConversion.temperature(celsius: v, to: preferences.temperature), preferences.temperature.symbol)
        case .speed:
            return (UnitConversion.speed(kilometersPerHour: v, to: preferences.speed), preferences.speed.symbol)
        default:
            return (v, quantity.baseUnitSymbol)
        }
    }

    /// Precision chosen to match sensor resolution, not to look precise.
    /// MAP resolution is 1 kPa ≈ 0.145 psi ≈ 0.01 bar.
    func defaultFractionDigits(_ quantity: Quantity) -> Int {
        switch quantity {
        case .pressure:
            switch preferences.pressure {
            case .psi: return 1
            case .kilopascal: return 0
            case .bar: return 2
            }
        case .ratio: return 3
        case .voltage, .angle, .massFlow, .volumeFlow: return 1
        default: return 0
        }
    }
}
