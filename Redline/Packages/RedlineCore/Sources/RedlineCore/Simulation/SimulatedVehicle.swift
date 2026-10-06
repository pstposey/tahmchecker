import Foundation

/// Driving scenarios for the simulator.
public enum SimulationScenario: String, Sendable, Codable, CaseIterable, Identifiable {
    case idle
    case cruise
    case acceleration
    case boostPull
    case deceleration
    case engineOff
    /// Cycles idle → acceleration → boost pull → deceleration → cruise.
    case autoCycle

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .idle: return "Idle"
        case .cruise: return "Cruise"
        case .acceleration: return "Acceleration"
        case .boostPull: return "Boost Pull"
        case .deceleration: return "Deceleration"
        case .engineOff: return "Engine Off"
        case .autoCycle: return "Auto Cycle"
        }
    }
}

/// A deliberately simple, plausible vehicle model. Its only job is to make
/// development possible without the car; it is not a physics model and
/// nothing it produces is ever presented as real telemetry.
///
/// Values are in base units (kPa, °C, km/h, rpm, %).
public final class SimulatedVehicle: Sendable {
    public struct Parameters: Sendable {
        /// Simulated ambient pressure. Default ≈ 1,600 m elevation.
        public var barometricKPa: Double = 83
        public var ambientC: Double = 18
        public var idleRPM: Double = 750
        /// Peak boost the model can reach (gauge, kPa).
        public var maxBoostKPa: Double = 115
        public init() {}
    }

    public struct Snapshot: Sendable {
        public var rpm: Double
        public var speedKmh: Double
        public var throttlePct: Double
        public var pedalPct: Double
        public var loadPct: Double
        public var mapKPa: Double
        public var baroKPa: Double
        public var coolantC: Double
        public var iatC: Double
        public var timingDeg: Double
        public var stftPct: Double
        public var ltftPct: Double
        public var commandedLambda: Double
        public var measuredLambda: Double
        public var railPressureKPa: Double
        public var voltage: Double
        public var fuelLevelPct: Double
        public var runTimeS: Double
        public var mafGs: Double
    }

    private struct State {
        var scenario: SimulationScenario = .autoCycle
        var scenarioStartedAt: Double = 0
        var lastUpdate: Double?
        var rpm: Double = 0
        var speed: Double = 0
        var throttle: Double = 0
        var pedal: Double = 0
        var map: Double = 83
        var coolant: Double = 60
        var iat: Double = 25
        var runTime: Double = 0
        var fuel: Double = 62
        var rng = SplitMix64(seed: 0x5EED)
    }

    public let parameters: Parameters
    private let state: Locked<State>
    private let epoch = ContinuousClock().now

    public init(parameters: Parameters = Parameters(), scenario: SimulationScenario = .autoCycle) {
        self.parameters = parameters
        var s = State()
        s.scenario = scenario
        s.map = parameters.barometricKPa
        self.state = Locked(s)
    }

    public var scenario: SimulationScenario { state.withLock { $0.scenario } }

    public func setScenario(_ scenario: SimulationScenario) {
        let t = now()
        state.withLock {
            $0.scenario = scenario
            $0.scenarioStartedAt = t
        }
    }

    /// Advances the model to the current time and returns its state.
    public func snapshot() -> Snapshot {
        let t = now()
        return state.withLock { s in
            advance(&s, to: t)
            return makeSnapshot(&s)
        }
    }

    private func now() -> Double { (ContinuousClock().now - epoch).seconds }

    // MARK: Model

    private struct Targets {
        var engineRunning = true
        var pedal: Double
        var rpm: Double
        var speed: Double
        var boostFraction: Double // 0 = vacuum, 1 = max boost
    }

    private func targets(_ scenario: SimulationScenario, elapsed: Double) -> Targets {
        switch scenario {
        case .idle:
            return Targets(pedal: 0, rpm: parameters.idleRPM, speed: 0, boostFraction: 0)
        case .cruise:
            return Targets(pedal: 18, rpm: 2_000, speed: 100, boostFraction: 0.05)
        case .acceleration:
            let rpm = min(2_500 + elapsed * 450, 5_200)
            return Targets(pedal: 60, rpm: rpm, speed: min(30 + elapsed * 6, 140), boostFraction: 0.55)
        case .boostPull:
            let rpm = min(2_800 + elapsed * 700, 6_100)
            return Targets(pedal: 100, rpm: rpm, speed: min(50 + elapsed * 9, 170), boostFraction: 1.0)
        case .deceleration:
            return Targets(pedal: 0, rpm: max(2_600 - elapsed * 250, 1_100), speed: max(110 - elapsed * 6, 20),
                           boostFraction: -0.2)
        case .engineOff:
            return Targets(engineRunning: false, pedal: 0, rpm: 0, speed: 0, boostFraction: 0)
        case .autoCycle:
            let cycle: [(SimulationScenario, Double)] = [
                (.idle, 6), (.acceleration, 6), (.boostPull, 5), (.deceleration, 6), (.cruise, 8),
            ]
            let total = cycle.reduce(0) { $0 + $1.1 }
            var t = elapsed.truncatingRemainder(dividingBy: total)
            for (phase, length) in cycle {
                if t < length { return targets(phase, elapsed: t) }
                t -= length
            }
            return targets(.idle, elapsed: 0)
        }
    }

    private func advance(_ s: inout State, to t: Double) {
        let dt = min(max(t - (s.lastUpdate ?? t), 0), 1)
        s.lastUpdate = t
        let target = targets(s.scenario, elapsed: t - s.scenarioStartedAt)
        func approach(_ value: Double, _ goal: Double, tau: Double) -> Double {
            value + (goal - value) * (1 - exp(-dt / tau))
        }
        s.pedal = approach(s.pedal, target.pedal, tau: 0.12)
        s.throttle = approach(s.throttle, target.engineRunning ? max(target.pedal * 0.9, 4) : 0, tau: 0.15)
        s.rpm = approach(s.rpm, target.rpm, tau: target.engineRunning ? 0.6 : 0.4)
        s.speed = approach(s.speed, target.speed, tau: 4)

        let baro = parameters.barometricKPa
        let mapTarget: Double
        if !target.engineRunning {
            mapTarget = baro
        } else if target.boostFraction > 0 {
            // Spool limited at low rpm.
            let spool = min(max((s.rpm - 1_600) / 1_400, 0), 1)
            let vacuumAtLightLoad = baro * 0.38
            let wot = baro + parameters.maxBoostKPa * target.boostFraction * spool
            mapTarget = target.boostFraction < 0.1 ? vacuumAtLightLoad + 25 : max(wot, vacuumAtLightLoad)
        } else if target.boostFraction < 0 {
            mapTarget = baro * 0.28 // closed throttle overrun: deep vacuum
        } else {
            mapTarget = baro * 0.37 // idle: ≈ 31 kPa at 83 kPa BARO
        }
        s.map = approach(s.map, mapTarget, tau: 0.35)

        if target.engineRunning {
            s.coolant = approach(s.coolant, 90, tau: 120)
            s.runTime += dt
        }
        let boostHeat = max(s.map - baro, 0) * 0.15
        s.iat = approach(s.iat, parameters.ambientC + 12 + boostHeat, tau: 8)
        s.fuel = max(s.fuel - dt * 0.0005, 0)
    }

    /// Called with the state lock held; must not re-enter `state`.
    private func makeSnapshot(_ s: inout State) -> Snapshot {
        var rng = s.rng
        defer { s.rng = rng }
        func noise(_ amplitude: Double) -> Double { (rng.nextUnit() * 2 - 1) * amplitude }
        let running = s.rpm > 300
        let load = running ? min(max(s.map / parameters.barometricKPa * 55 + noise(1), 0), 100) : 0
        let snapshot = Snapshot(
            rpm: running ? max(s.rpm + noise(12), 0) : 0,
            speedKmh: max(s.speed, 0),
            throttlePct: s.throttle,
            pedalPct: s.pedal * 0.8 + 15, // pedal sensors rarely read 0–100 %
            loadPct: load,
            mapKPa: max(s.map + noise(0.6), 10),
            baroKPa: parameters.barometricKPa,
            coolantC: s.coolant,
            iatC: s.iat,
            timingDeg: running ? 12 + (s.map < parameters.barometricKPa ? 8 : -6) + noise(1.5) : 0,
            stftPct: running ? noise(3) : 0,
            ltftPct: 1.6,
            commandedLambda: s.map > parameters.barometricKPa + 40 ? 0.82 : 1.0,
            measuredLambda: running ? (s.map > parameters.barometricKPa + 40 ? 0.83 : 1.0 + noise(0.02)) : 1.99,
            railPressureKPa: running ? 5_000 + max(s.map - parameters.barometricKPa, 0) * 80 : 400,
            voltage: running ? 14.1 + noise(0.05) : 12.4,
            fuelLevelPct: s.fuel,
            runTimeS: s.runTime,
            mafGs: running ? s.rpm * s.map / 12_000 : 0
        )
        return snapshot
    }

    /// Base-unit value for a channel, nil if the simulated car lacks it.
    public func value(for channel: ChannelID, in s: Snapshot) -> Double? {
        switch channel {
        case .engineRPM: return s.rpm
        case .vehicleSpeed: return s.speedKmh
        case .engineLoad: return s.loadPct
        case .absoluteLoad: return s.loadPct * 0.9
        case .coolantTemp: return s.coolantC
        case .intakeAirTemp: return s.iatC
        case .manifoldPressure: return s.mapKPa
        case .barometricPressure: return s.baroKPa
        case .ambientAirTemp: return parameters.ambientC
        case .throttlePosition: return s.throttlePct
        case .relativeThrottle: return max(s.throttlePct - 4, 0)
        case .commandedThrottle: return s.throttlePct
        case .acceleratorPedalD: return s.pedalPct
        case .acceleratorPedalE: return s.pedalPct / 2
        case .timingAdvance: return s.timingDeg
        case .shortTermFuelTrim1: return s.stftPct
        case .longTermFuelTrim1: return s.ltftPct
        case .commandedLambda: return s.commandedLambda
        case .o2Sensor1LambdaI: return s.measuredLambda
        case .fuelRailGaugePressure: return s.railPressureKPa
        case .moduleVoltage: return s.voltage
        case .fuelLevel: return s.fuelLevelPct
        case .engineRunTime: return s.runTimeS
        case .mafAirFlow: return s.mafGs
        default: return nil // e.g. oil temp: not simulated, so reported unsupported
        }
    }
}

/// Small deterministic PRNG so simulator output is reproducible.
struct SplitMix64: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
