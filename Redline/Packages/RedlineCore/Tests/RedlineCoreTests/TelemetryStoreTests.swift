import Foundation
import Testing
@testable import RedlineCore

@MainActor
@Suite("Telemetry store")
struct TelemetryStoreTests {
    let clock = ContinuousClock()

    func sample(_ id: ChannelID, _ value: Double, at t: MonotonicInstant, valid: Bool = true) -> TelemetrySample {
        TelemetrySample(channel: id, value: value, source: .ecuReported, isValid: valid,
                        timing: SampleTiming(requestedAt: t, receivedAt: t, decodedAt: t))
    }

    @Test func boostRequiresBaroAndNeverAssumesSeaLevel() {
        let store = TelemetryStore()
        let t = clock.now
        store.apply([.support(.manifoldPressure, .supported), .support(.barometricPressure, .supported)])
        store.apply([.sample(sample(.manifoldPressure, 31, at: t))])
        #expect(store.channel(.boost)!.latest == nil) // no BARO yet → "--", not MAP − 101.325

        store.apply([.sample(sample(.barometricPressure, 83, at: t))])
        store.apply([.sample(sample(.manifoldPressure, 31, at: t + .milliseconds(100)))])
        let boost = store.channel(.boost)!
        #expect(boost.latest?.value == -52)
        #expect(boost.latest?.source == .calculated)
        #expect(boost.peak == nil) // vacuum is not peak boost

        store.apply([.sample(sample(.manifoldPressure, 198, at: t + .milliseconds(200)))])
        #expect(boost.latest?.value == 115)
        #expect(boost.peak == 115)
    }

    @Test func boostUnavailableWhenBaroUnsupported() {
        let store = TelemetryStore()
        store.apply([.support(.manifoldPressure, .supported), .support(.barometricPressure, .unsupported)])
        let boost = store.channel(.boost)!
        guard case .unavailable(let why) = boost.displayStatus else {
            Issue.record("expected unavailable, got \(boost.displayStatus)")
            return
        }
        #expect(why.contains("BARO"))
    }

    @Test func unsupportedIsNotZero() {
        let store = TelemetryStore()
        store.apply([.support(.oilTemp, .unsupported)])
        #expect(store.channel(.oilTemp)!.displayStatus == .unsupported)
        #expect(store.channel(.oilTemp)!.latest == nil)
        // Supported but no sample yet → waiting ("--").
        store.apply([.support(.engineRPM, .supported)])
        #expect(store.channel(.engineRPM)!.displayStatus == .waiting)
    }

    @Test func invalidSamplesAreNotDisplayed() {
        let store = TelemetryStore()
        let t = clock.now
        store.apply([.sample(sample(.engineRPM, 750, at: t))])
        store.apply([.sample(sample(.engineRPM, 16_000, at: t + .milliseconds(50), valid: false))])
        let rpm = store.channel(.engineRPM)!
        #expect(rpm.latest?.value == 750)
        #expect(rpm.invalidCount == 1)
        #expect(rpm.lastInvalid?.value == 16_000)
        #expect(rpm.peak == 750)
    }

    @Test func stalenessIsChannelSpecific() {
        let store = TelemetryStore()
        let t = clock.now
        store.apply([.sample(sample(.engineRPM, 750, at: t)), .sample(sample(.fuelLevel, 50, at: t))])
        store.sweepStaleness(now: t + .seconds(1))
        #expect(store.channel(.engineRPM)!.displayStatus == .live)

        // 2.5 s: fast RPM is stale (2 s), slow fuel level is not (10 s).
        store.sweepStaleness(now: t + .milliseconds(2_500))
        #expect(store.channel(.engineRPM)!.displayStatus == .stale)
        #expect(store.channel(.fuelLevel)!.displayStatus == .live)

        // A new sample clears staleness.
        store.apply([.sample(sample(.engineRPM, 800, at: t + .seconds(3)))])
        #expect(store.channel(.engineRPM)!.displayStatus == .live)
    }

    @Test func observedRateIsMeasured() {
        let store = TelemetryStore()
        let t = clock.now
        for i in 0..<20 {
            store.apply([.sample(sample(.engineRPM, 750, at: t + .milliseconds(100 * i)))])
        }
        let hz = store.channel(.engineRPM)!.observedRateHz!
        #expect(abs(hz - 10) < 0.01)
    }

    @Test func resetSessionClearsEverything() {
        let store = TelemetryStore()
        store.apply([.support(.engineRPM, .supported), .sample(sample(.engineRPM, 750, at: clock.now))])
        store.resetSession(sourceKind: .simulated)
        let rpm = store.channel(.engineRPM)!
        #expect(rpm.latest == nil)
        #expect(rpm.support == .unknown)
        #expect(store.sourceKind == .simulated)
    }
}

@Suite("Performance monitor")
struct PerformanceMonitorTests {
    @Test func percentilesAndRates() {
        let m = PerformanceMonitor(window: .seconds(5))
        let t0 = ContinuousClock().now
        for i in 1...10 {
            let sent = t0 + .milliseconds(100 * i)
            m.record(ExchangeRecord(command: "010C", sentAt: sent, firstByteAt: sent + .milliseconds(15),
                                    completedAt: sent + .milliseconds(10 * i), decodedAt: sent + .milliseconds(10 * i),
                                    outcome: .success))
        }
        let sent = t0 + .seconds(1)
        m.record(ExchangeRecord(command: "0133", sentAt: sent, firstByteAt: nil, completedAt: sent + .seconds(1),
                                decodedAt: nil, outcome: .timeout))
        let snap = m.snapshot(now: t0 + .seconds(3))
        #expect(snap.totalRequests == 11)
        #expect(snap.totalTimeouts == 1)
        #expect(snap.medianRoundTripMs == 50)
        #expect(snap.p95RoundTripMs == 100)
        #expect(snap.maxRoundTripMs == 100)
        #expect(snap.successPerSecond == 2) // 10 in a 5 s window
        #expect(snap.perCommand.first { $0.command == "010C" }?.successesInWindow == 10)
        #expect(PerformanceMonitor.percentile([], 0.5) == nil)
    }
}
