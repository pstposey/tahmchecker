import Testing
@testable import RedlineCore

@Suite("PID formulas")
struct PIDDecodingTests {
    func value(_ channel: ChannelID, _ bytes: [UInt8]) -> Double? {
        StandardPIDs.definition(for: channel)!.formula.evaluate(bytes)
    }

    @Test func rpm() {
        // (256 × 0x1A + 0xF8) / 4 = 6904 / 4 = 1726
        #expect(value(.engineRPM, [0x1A, 0xF8]) == 1726)
        #expect(value(.engineRPM, [0x0B, 0xB8]) == 750)
        #expect(value(.engineRPM, [0xFF, 0xFF]) == 16_383.75)
        #expect(value(.engineRPM, [0x1A]) == nil) // too short
    }

    @Test func temperatures() {
        #expect(value(.coolantTemp, [0x82]) == 90) // 130 − 40
        #expect(value(.coolantTemp, [0x00]) == -40)
        #expect(value(.coolantTemp, [0xFF]) == 215)
        #expect(value(.intakeAirTemp, [0x41]) == 25)
    }

    @Test func pressures() {
        #expect(value(.manifoldPressure, [0x1F]) == 31)
        #expect(value(.barometricPressure, [0x53]) == 83)
        #expect(value(.fuelPressure, [0x64]) == 300)
        #expect(value(.fuelRailGaugePressure, [0x01, 0xF4]) == 5_000)
        #expect(abs(value(.fuelRailPressureRelative, [0x00, 0x64])! - 7.9) < 1e-9)
    }

    @Test func percentages() {
        #expect(value(.engineLoad, [0xFF]) == 100)
        #expect(value(.engineLoad, [0x00]) == 0)
        #expect(abs(value(.throttlePosition, [0x80])! - 50.196) < 0.001)
        // Fuel trims: A × 100/128 − 100
        #expect(value(.shortTermFuelTrim1, [0x80]) == 0)
        #expect(value(.shortTermFuelTrim1, [0x00]) == -100)
        #expect(abs(value(.longTermFuelTrim1, [0xFF])! - 99.21875) < 1e-9)
        #expect(abs(value(.absoluteLoad, [0x00, 0xFF])! - 100) < 1e-9)
    }

    @Test func miscellaneous() {
        #expect(value(.timingAdvance, [0x80]) == 0) // 128/2 − 64
        #expect(value(.timingAdvance, [0x98]) == 12)
        #expect(abs(value(.moduleVoltage, [0x37, 0x14])! - 14.1) < 1e-9) // 14100 / 1000
        #expect(value(.commandedLambda, [0x80, 0x00]) == 1.0) // 32768 × 2/65536
        #expect(value(.o2Sensor1LambdaI, [0x80, 0x00, 0x80, 0x00]) == 1.0)
        #expect(abs(value(.mafAirFlow, [0x01, 0x2C])! - 3.0) < 1e-9)
        #expect(value(.engineRunTime, [0x01, 0x00]) == 256)
        #expect(abs(value(.fuelRate, [0x00, 0x64])! - 5) < 1e-9)
    }

    @Test func encodeIsInverseOfEvaluate() {
        for def in StandardPIDs.all {
            let range: [Double]
            switch def.channel.quantity {
            case .temperature: range = [-40, 0, 90, 215]
            case .percent: range = def.formula == .a(scale: 100.0 / 128.0, offset: -100) ? [-100, 0, 25] : [0, 50, 100]
            case .rotationalSpeed: range = [0, 750, 1726, 6500]
            case .ratio: range = [0.8, 1.0, 1.5]
            case .angle: range = [-10, 0, 20]
            case .voltage: range = [12.4, 14.1]
            case .pressure: range = [0, 31, 83, 198]
            default: range = [0, 10, 100]
            }
            for v in range {
                let bytes = def.formula.encode(v, totalBytes: def.responseLength)
                let decoded = def.formula.evaluate(bytes)!
                let resolution: Double
                if case .linear(_, _, let scale, _) = def.formula { resolution = scale } else { resolution = 1 }
                #expect(abs(decoded - v) <= resolution / 2 + 1e-9, "\(def.key) \(v) → \(decoded)")
            }
        }
    }

    @Test func plausibilityFlagsGrossErrorsWithoutClamping() {
        let rpm = StandardPIDs.definition(for: .engineRPM)!.channel
        #expect(rpm.isPlausible(6_500))
        #expect(!rpm.isPlausible(16_000))
        let baro = StandardPIDs.definition(for: .barometricPressure)!.channel
        #expect(baro.isPlausible(83))
        #expect(!baro.isPlausible(255))
        #expect(!baro.isPlausible(.nan))
    }

    @Test func catalogIsConsistent() {
        #expect(Set(StandardPIDs.all.map(\.key)).count == StandardPIDs.all.count)
        #expect(Set(StandardPIDs.allChannels.map(\.id)).count == StandardPIDs.allChannels.count)
        for def in StandardPIDs.all {
            #expect(def.formula.requiredBytes <= def.responseLength)
            #expect(def.mode == 0x01)
        }
        #expect(StandardPIDs.definition(for: .engineRPM)!.key.requestCommand == "010C")
    }
}

@Suite("Supported PID discovery")
struct PIDSupportTests {
    @Test func decodesBitmask() {
        // Classic example: 41 00 BE 1F A8 13
        let pids = PIDSupportMap.decodeBitmask(base: 0x00, data: [0xBE, 0x1F, 0xA8, 0x13])
        #expect(pids == [0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x13, 0x15, 0x1C, 0x1F, 0x20])
    }

    @Test func rangeWalk() {
        var map = PIDSupportMap()
        #expect(map.nextRangeToQuery() == 0x00)
        map.record(base: 0x00, bitmask: [0x00, 0x00, 0x00, 0x01], from: .can11(0x7E8)) // only 0x20
        #expect(map.nextRangeToQuery() == 0x20)
        map.record(base: 0x20, bitmask: [0x00, 0x00, 0x20, 0x00], from: .can11(0x7E8)) // 0x33, no 0x40
        #expect(map.nextRangeToQuery() == nil)
        #expect(map.isSupported(0x33))
        #expect(!map.isSupported(0x0C))
    }

    @Test func prefersEngineECU() {
        var map = PIDSupportMap()
        map.record(base: 0x00, bitmask: [0x00, 0x10, 0x00, 0x00], from: .can11(0x7E9)) // 0x0C
        map.record(base: 0x00, bitmask: [0x00, 0x10, 0x00, 0x00], from: .can11(0x7E8))
        #expect(map.ecus(supporting: 0x0C) == [.can11(0x7E8), .can11(0x7E9)])
        #expect(map.respondingECUs == [.can11(0x7E8), .can11(0x7E9)])
    }
}
