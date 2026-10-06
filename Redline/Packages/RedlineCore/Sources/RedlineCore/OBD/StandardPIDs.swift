extension ChannelID {
    public static let engineRPM: ChannelID = "engine.rpm"
    public static let vehicleSpeed: ChannelID = "vehicle.speed"
    public static let engineLoad: ChannelID = "engine.load"
    public static let absoluteLoad: ChannelID = "engine.absoluteLoad"
    public static let coolantTemp: ChannelID = "engine.coolantTemp"
    public static let oilTemp: ChannelID = "engine.oilTemp"
    public static let intakeAirTemp: ChannelID = "intake.airTemp"
    public static let manifoldPressure: ChannelID = "intake.manifoldAbsolutePressure"
    public static let mafAirFlow: ChannelID = "intake.maf"
    public static let barometricPressure: ChannelID = "ambient.barometricPressure"
    public static let ambientAirTemp: ChannelID = "ambient.airTemp"
    public static let throttlePosition: ChannelID = "engine.throttlePosition"
    public static let relativeThrottle: ChannelID = "engine.relativeThrottle"
    public static let throttlePositionB: ChannelID = "engine.throttlePositionB"
    public static let commandedThrottle: ChannelID = "engine.commandedThrottle"
    public static let acceleratorPedalD: ChannelID = "pedal.positionD"
    public static let acceleratorPedalE: ChannelID = "pedal.positionE"
    public static let relativePedal: ChannelID = "pedal.relative"
    public static let timingAdvance: ChannelID = "engine.timingAdvance"
    public static let shortTermFuelTrim1: ChannelID = "fuel.shortTermTrimB1"
    public static let longTermFuelTrim1: ChannelID = "fuel.longTermTrimB1"
    public static let fuelPressure: ChannelID = "fuel.pressure"
    public static let fuelRailPressureRelative: ChannelID = "fuel.railPressureRelative"
    public static let fuelRailGaugePressure: ChannelID = "fuel.railGaugePressure"
    public static let fuelRailAbsolutePressure: ChannelID = "fuel.railAbsolutePressure"
    public static let commandedLambda: ChannelID = "fuel.commandedLambda"
    public static let o2Sensor1LambdaV: ChannelID = "o2.sensor1.lambda.voltageType"
    public static let o2Sensor1LambdaI: ChannelID = "o2.sensor1.lambda.currentType"
    public static let fuelLevel: ChannelID = "fuel.level"
    public static let fuelRate: ChannelID = "fuel.rate"
    public static let moduleVoltage: ChannelID = "electrical.moduleVoltage"
    public static let engineRunTime: ChannelID = "engine.runTime"

    /// Calculated: MAP − BARO.
    public static let boost: ChannelID = "calc.boost"
}

/// Standard SAE J1979 / ISO 15031-5 service 01 PIDs used by Redline.
///
/// Formulas are the standard scalings; each was cross-checked against the
/// unit-and-scaling table implemented by python-OBD (UAS IDs noted below)
/// and its decoders. Test vectors live in `PIDDecodingTests`.
///
/// This is intentionally not every SAE PID — only the ones Redline uses.
/// Support is always discovered from the vehicle (service 01 PIDs 00/20/40/…);
/// nothing here is assumed to exist on a given car.
public enum StandardPIDs {
    private static let percent255 = 100.0 / 255.0
    private static let lambdaScale = 2.0 / 65_536.0 // UAS 0x1E (≈0.0000305)

    public static let all: [PIDDefinition] = [
        pid(0x04, 1, .a(scale: percent255),
            .init(id: .engineLoad, name: "Calculated Engine Load", shortName: "LOAD", quantity: .percent,
                  category: .engine, pollingClass: .fast, peakPolicy: .maximum, fractionDigits: 0,
                  notes: "PID 04: A × 100/255 %")),
        pid(0x05, 1, .a(offset: -40),
            .init(id: .coolantTemp, name: "Engine Coolant Temperature", shortName: "COOLANT", quantity: .temperature,
                  category: .temperature, pollingClass: .slow, peakPolicy: .maximum,
                  notes: "PID 05: A − 40 °C")),
        pid(0x06, 1, .a(scale: 100.0 / 128.0, offset: -100),
            .init(id: .shortTermFuelTrim1, name: "Short Term Fuel Trim — Bank 1", shortName: "STFT", quantity: .percent,
                  category: .fuel, pollingClass: .medium, fractionDigits: 1,
                  notes: "PID 06: A × 100/128 − 100 %")),
        pid(0x07, 1, .a(scale: 100.0 / 128.0, offset: -100),
            .init(id: .longTermFuelTrim1, name: "Long Term Fuel Trim — Bank 1", shortName: "LTFT", quantity: .percent,
                  category: .fuel, pollingClass: .medium, fractionDigits: 1,
                  notes: "PID 07: A × 100/128 − 100 %")),
        pid(0x0A, 1, .a(scale: 3),
            .init(id: .fuelPressure, name: "Fuel Pressure (gauge)", shortName: "FUEL P", quantity: .pressure,
                  category: .fuel, pollingClass: .medium,
                  notes: "PID 0A: 3A kPa (gauge)")),
        pid(0x0B, 1, .a(),
            .init(id: .manifoldPressure, name: "Intake Manifold Absolute Pressure", shortName: "MAP", quantity: .pressure,
                  category: .airPath, pollingClass: .fast, peakPolicy: .maximum,
                  notes: "PID 0B: A kPa absolute. 1 kPa resolution (≈0.145 psi); 255 kPa ceiling.")),
        pid(0x0C, 2, .ab(scale: 0.25),
            .init(id: .engineRPM, name: "Engine Speed", shortName: "RPM", quantity: .rotationalSpeed,
                  category: .engine, pollingClass: .fast, plausibleRange: 0...12_000, peakPolicy: .maximum,
                  fractionDigits: 0,
                  notes: "PID 0C: (256A + B) / 4 rpm (UAS 0x07)")),
        pid(0x0D, 1, .a(),
            .init(id: .vehicleSpeed, name: "Vehicle Speed", shortName: "SPEED", quantity: .speed,
                  category: .vehicle, pollingClass: .medium, peakPolicy: .maximum,
                  notes: "PID 0D: A km/h (UAS 0x09)")),
        pid(0x0E, 1, .a(scale: 0.5, offset: -64),
            .init(id: .timingAdvance, name: "Ignition Timing Advance (cyl. 1)", shortName: "TIMING", quantity: .angle,
                  category: .engine, pollingClass: .medium, fractionDigits: 1,
                  notes: "PID 0E: A/2 − 64 ° before TDC")),
        pid(0x0F, 1, .a(offset: -40),
            .init(id: .intakeAirTemp, name: "Intake Air Temperature", shortName: "IAT", quantity: .temperature,
                  category: .temperature, pollingClass: .medium, peakPolicy: .maximum,
                  notes: "PID 0F: A − 40 °C")),
        pid(0x10, 2, .ab(scale: 0.01),
            .init(id: .mafAirFlow, name: "Mass Air Flow", shortName: "MAF", quantity: .massFlow,
                  category: .airPath, pollingClass: .medium, peakPolicy: .maximum, fractionDigits: 1,
                  notes: "PID 10: (256A + B) / 100 g/s (UAS 0x27)")),
        pid(0x11, 1, .a(scale: percent255),
            .init(id: .throttlePosition, name: "Throttle Position", shortName: "THROTTLE", quantity: .percent,
                  category: .engine, pollingClass: .fast, fractionDigits: 0,
                  notes: "PID 11: A × 100/255 %")),
        pid(0x1F, 2, .ab(),
            .init(id: .engineRunTime, name: "Run Time Since Engine Start", shortName: "RUN TIME", quantity: .duration,
                  category: .engine, pollingClass: .slow,
                  notes: "PID 1F: 256A + B s (UAS 0x12)")),
        pid(0x22, 2, .ab(scale: 0.079),
            .init(id: .fuelRailPressureRelative, name: "Fuel Rail Pressure (rel. manifold vacuum)", shortName: "FRP REL",
                  quantity: .pressure, category: .fuel, pollingClass: .medium,
                  notes: "PID 22: 0.079 × (256A + B) kPa (UAS 0x19)")),
        pid(0x23, 2, .ab(scale: 10),
            .init(id: .fuelRailGaugePressure, name: "Fuel Rail Gauge Pressure", shortName: "FRP", quantity: .pressure,
                  category: .fuel, pollingClass: .medium, peakPolicy: .maximum,
                  notes: "PID 23: 10 × (256A + B) kPa gauge (UAS 0x1B)")),
        pid(0x24, 4, .ab(scale: lambdaScale),
            .init(id: .o2Sensor1LambdaV, name: "O2 Sensor 1 Equivalence Ratio (wide-range, voltage)", shortName: "λ S1",
                  quantity: .ratio, category: .fuel, pollingClass: .medium, fractionDigits: 3,
                  notes: "PID 24 AB: 2/65536 × (256A + B) λ. Sensor location per PID 13/1D.")),
        pid(0x2F, 1, .a(scale: percent255),
            .init(id: .fuelLevel, name: "Fuel Tank Level Input", shortName: "FUEL", quantity: .percent,
                  category: .fuel, pollingClass: .slow, fractionDigits: 0,
                  notes: "PID 2F: A × 100/255 %")),
        pid(0x33, 1, .a(),
            .init(id: .barometricPressure, name: "Absolute Barometric Pressure", shortName: "BARO", quantity: .pressure,
                  category: .airPath, pollingClass: .slow, plausibleRange: 45...110,
                  notes: "PID 33: A kPa absolute")),
        pid(0x34, 4, .ab(scale: lambdaScale),
            .init(id: .o2Sensor1LambdaI, name: "O2 Sensor 1 Equivalence Ratio (wide-range, current)", shortName: "λ S1",
                  quantity: .ratio, category: .fuel, pollingClass: .medium, fractionDigits: 3,
                  notes: "PID 34 AB: 2/65536 × (256A + B) λ. Sensor location per PID 13/1D.")),
        pid(0x42, 2, .ab(scale: 0.001),
            .init(id: .moduleVoltage, name: "Control Module Voltage", shortName: "VOLTS", quantity: .voltage,
                  category: .electrical, pollingClass: .slow, plausibleRange: 0...32, fractionDigits: 1,
                  notes: "PID 42: (256A + B) / 1000 V (UAS 0x0B)")),
        pid(0x43, 2, .ab(scale: percent255),
            .init(id: .absoluteLoad, name: "Absolute Load Value", shortName: "ABS LOAD", quantity: .percent,
                  category: .engine, pollingClass: .medium, peakPolicy: .maximum, fractionDigits: 0,
                  notes: "PID 43: (256A + B) × 100/255 %")),
        pid(0x44, 2, .ab(scale: lambdaScale),
            .init(id: .commandedLambda, name: "Commanded Equivalence Ratio", shortName: "CMD λ", quantity: .ratio,
                  category: .fuel, pollingClass: .medium, fractionDigits: 3,
                  notes: "PID 44: 2/65536 × (256A + B) (UAS 0x1E)")),
        pid(0x45, 1, .a(scale: percent255),
            .init(id: .relativeThrottle, name: "Relative Throttle Position", shortName: "REL THR", quantity: .percent,
                  category: .engine, pollingClass: .medium, fractionDigits: 0,
                  notes: "PID 45: A × 100/255 %")),
        pid(0x46, 1, .a(offset: -40),
            .init(id: .ambientAirTemp, name: "Ambient Air Temperature", shortName: "AMBIENT", quantity: .temperature,
                  category: .temperature, pollingClass: .slow,
                  notes: "PID 46: A − 40 °C")),
        pid(0x47, 1, .a(scale: percent255),
            .init(id: .throttlePositionB, name: "Absolute Throttle Position B", shortName: "THR B", quantity: .percent,
                  category: .engine, pollingClass: .medium, fractionDigits: 0,
                  notes: "PID 47: A × 100/255 %")),
        pid(0x49, 1, .a(scale: percent255),
            .init(id: .acceleratorPedalD, name: "Accelerator Pedal Position D", shortName: "PEDAL", quantity: .percent,
                  category: .engine, pollingClass: .fast, fractionDigits: 0,
                  notes: "PID 49: A × 100/255 % (raw sensor; not 0–100 of travel)")),
        pid(0x4A, 1, .a(scale: percent255),
            .init(id: .acceleratorPedalE, name: "Accelerator Pedal Position E", shortName: "PEDAL E", quantity: .percent,
                  category: .engine, pollingClass: .medium, fractionDigits: 0,
                  notes: "PID 4A: A × 100/255 %")),
        pid(0x4C, 1, .a(scale: percent255),
            .init(id: .commandedThrottle, name: "Commanded Throttle Actuator", shortName: "CMD THR", quantity: .percent,
                  category: .engine, pollingClass: .medium, fractionDigits: 0,
                  notes: "PID 4C: A × 100/255 %")),
        pid(0x59, 2, .ab(scale: 10),
            .init(id: .fuelRailAbsolutePressure, name: "Fuel Rail Absolute Pressure", shortName: "FRP ABS",
                  quantity: .pressure, category: .fuel, pollingClass: .medium, peakPolicy: .maximum,
                  notes: "PID 59: 10 × (256A + B) kPa absolute (UAS 0x1B)")),
        pid(0x5A, 1, .a(scale: percent255),
            .init(id: .relativePedal, name: "Relative Accelerator Pedal Position", shortName: "REL PEDAL",
                  quantity: .percent, category: .engine, pollingClass: .medium, fractionDigits: 0,
                  notes: "PID 5A: A × 100/255 %")),
        pid(0x5C, 1, .a(offset: -40),
            .init(id: .oilTemp, name: "Engine Oil Temperature", shortName: "OIL", quantity: .temperature,
                  category: .temperature, pollingClass: .slow, peakPolicy: .maximum,
                  notes: "PID 5C: A − 40 °C (ECU-reported; only if the vehicle supports PID 5C)")),
        pid(0x5E, 2, .ab(scale: 0.05),
            .init(id: .fuelRate, name: "Engine Fuel Rate", shortName: "FUEL RATE", quantity: .volumeFlow,
                  category: .fuel, pollingClass: .medium, fractionDigits: 1,
                  notes: "PID 5E: (256A + B) / 20 L/h")),
    ]

    /// Boost is derived, never requested.
    public static let boostChannel = ChannelDescriptor(
        id: .boost, name: "Boost (gauge pressure)", shortName: "BOOST", quantity: .pressure,
        source: .calculated, category: .airPath, pollingClass: .fast, peakPolicy: .maximumPositive,
        notes: "MAP (PID 0B) − BARO (PID 33). Negative = vacuum. Uses the most recent valid BARO; never assumes sea level."
    )

    public static let byChannel: [ChannelID: PIDDefinition] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    public static let byKey: [PIDKey: PIDDefinition] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    public static func definition(for channel: ChannelID) -> PIDDefinition? { byChannel[channel] }

    /// Every channel Redline knows about (requested + calculated).
    public static var allChannels: [ChannelDescriptor] { all.map(\.channel) + [boostChannel] }

    private static func pid(_ pid: UInt8, _ length: Int, _ formula: PIDFormula, _ channel: ChannelDescriptor) -> PIDDefinition {
        PIDDefinition(mode: 0x01, pid: pid, responseLength: length, formula: formula, channel: channel,
                      reference: "SAE J1979 service 01 PID \(Hex.byteString(pid))")
    }
}
