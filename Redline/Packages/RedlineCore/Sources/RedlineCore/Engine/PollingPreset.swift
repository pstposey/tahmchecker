/// Which channels to request. Fewer channels → higher per-channel rate.
/// Until dashboard-driven polling exists (Phase 10), these presets are how
/// the polled set is chosen; they are also the tool for latency experiments.
public enum PollingPreset: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Milestone 1 baseline: the maximum single-channel rate.
    case rpmOnly
    /// Milestone 2: RPM + boost inputs + coolant sanity check.
    case rpmAndBoost
    /// Default turbo dashboard: Boost, RPM, Load, Throttle, Pedal, Coolant, IAT.
    /// Load is PID 43 (absolute load): PID 04's request (01 04) is refused by
    /// the read-only policy because its last two characters are "04".
    case turboDashboard
    /// Secondary diagnostic set.
    case diagnostic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .rpmOnly: return "RPM only"
        case .rpmAndBoost: return "RPM + Boost"
        case .turboDashboard: return "Turbo dashboard"
        case .diagnostic: return "Diagnostic"
        }
    }

    public var channels: [ChannelID] {
        switch self {
        case .rpmOnly:
            return [.engineRPM]
        case .rpmAndBoost:
            return [.engineRPM, .manifoldPressure, .barometricPressure, .coolantTemp]
        case .turboDashboard:
            return [.engineRPM, .manifoldPressure, .barometricPressure, .absoluteLoad, .throttlePosition,
                    .acceleratorPedalD, .coolantTemp, .intakeAirTemp]
        case .diagnostic:
            return [.engineRPM, .manifoldPressure, .barometricPressure, .shortTermFuelTrim1, .longTermFuelTrim1,
                    .timingAdvance, .fuelRailGaugePressure, .fuelRailAbsolutePressure, .commandedLambda,
                    .o2Sensor1LambdaI, .o2Sensor1LambdaV, .moduleVoltage, .coolantTemp, .intakeAirTemp]
        }
    }

    public var definitions: [PIDDefinition] { channels.compactMap(StandardPIDs.definition(for:)) }
}
