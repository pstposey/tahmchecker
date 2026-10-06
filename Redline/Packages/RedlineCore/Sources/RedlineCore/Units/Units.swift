import Foundation

public enum PressureUnit: String, Sendable, Codable, CaseIterable, Identifiable {
    case psi
    case kilopascal
    case bar

    public var id: String { rawValue }
    public var symbol: String {
        switch self {
        case .psi: return "PSI"
        case .kilopascal: return "kPa"
        case .bar: return "bar"
        }
    }
}

public enum TemperatureUnit: String, Sendable, Codable, CaseIterable, Identifiable {
    case fahrenheit
    case celsius

    public var id: String { rawValue }
    public var symbol: String { self == .fahrenheit ? "°F" : "°C" }
}

public enum SpeedUnit: String, Sendable, Codable, CaseIterable, Identifiable {
    case milesPerHour
    case kilometersPerHour

    public var id: String { rawValue }
    public var symbol: String { self == .milesPerHour ? "mph" : "km/h" }
}

public enum FuelEconomyUnit: String, Sendable, Codable, CaseIterable, Identifiable {
    case milesPerGallonUS
    case litersPer100Kilometers

    public var id: String { rawValue }
    public var symbol: String { self == .milesPerGallonUS ? "MPG" : "L/100 km" }
}

/// Display-unit choices. The ECU's units never dictate these.
public struct UnitPreferences: Sendable, Codable, Equatable {
    public var pressure: PressureUnit
    public var temperature: TemperatureUnit
    public var speed: SpeedUnit
    public var fuelEconomy: FuelEconomyUnit

    public init(
        pressure: PressureUnit = .psi,
        temperature: TemperatureUnit = .fahrenheit,
        speed: SpeedUnit = .milesPerHour,
        fuelEconomy: FuelEconomyUnit = .milesPerGallonUS
    ) {
        self.pressure = pressure
        self.temperature = temperature
        self.speed = speed
        self.fuelEconomy = fuelEconomy
    }

    /// Owner's default: PSI, °F, mph, MPG.
    public static let personalDefault = UnitPreferences()
    public static let metric = UnitPreferences(pressure: .kilopascal, temperature: .celsius,
                                               speed: .kilometersPerHour, fuelEconomy: .litersPer100Kilometers)
}

/// All unit conversion lives here. Constants are exact definitions.
public enum UnitConversion {
    /// 1 psi = 6.894757293168361 kPa (1 lbf/in² with standard gravity).
    public static let kilopascalsPerPSI = 6.894_757_293_168_361
    /// ≈ 0.1450377377
    public static let psiPerKilopascal = 1 / kilopascalsPerPSI
    /// 1 bar = 100 kPa.
    public static let kilopascalsPerBar = 100.0
    /// International mile: 1.609344 km exactly.
    public static let kilometersPerMile = 1.609_344
    /// US liquid gallon: 3.785411784 L exactly.
    public static let litersPerUSGallon = 3.785_411_784

    public static func pressure(kilopascals kPa: Double, to unit: PressureUnit) -> Double {
        switch unit {
        case .kilopascal: return kPa
        case .psi: return kPa * psiPerKilopascal
        case .bar: return kPa / kilopascalsPerBar
        }
    }

    public static func temperature(celsius c: Double, to unit: TemperatureUnit) -> Double {
        unit == .celsius ? c : c * 9 / 5 + 32
    }

    public static func speed(kilometersPerHour kmh: Double, to unit: SpeedUnit) -> Double {
        unit == .kilometersPerHour ? kmh : kmh / kilometersPerMile
    }

    /// Converts fuel consumption in L/100 km. Returns nil for 0 (MPG would
    /// be infinite), so callers can show "--" rather than a fake number.
    public static func fuelEconomy(litersPer100km l: Double, to unit: FuelEconomyUnit) -> Double? {
        switch unit {
        case .litersPer100Kilometers: return l
        case .milesPerGallonUS:
            guard l > 0 else { return nil }
            return 100 * litersPerUSGallon / (kilometersPerMile * l)
        }
    }
}
