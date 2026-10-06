import Testing
@testable import RedlineCore

@Suite("Units and boost")
struct UnitsAndBoostTests {
    // Brief §37: 115 kPa × 0.1450377377 ≈ 16.68 PSI.
    @Test func criticalPSIConversion() {
        let psi = UnitConversion.pressure(kilopascals: 115, to: .psi)
        #expect(abs(psi - 16.679_339_8) < 1e-6)
        #expect(abs(UnitConversion.psiPerKilopascal - 0.145_037_737_7) < 1e-10)
    }

    // Brief §10 field observations (sanity references, not specifications).
    @Test(arguments: [(-52.0, -7.54), (84.0, 12.18), (90.0, 13.05), (115.0, 16.68)])
    func fieldObservationConversions(kPa: Double, expectedPSI: Double) {
        let psi = UnitConversion.pressure(kilopascals: kPa, to: .psi)
        #expect(abs(psi - expectedPSI) < 0.005)
    }

    @Test func boostIsMAPMinusBARO() {
        // Warm idle observed: MAP ≈ 31 kPa absolute, boost ≈ −52 kPa → BARO ≈ 83 kPa.
        let idle = BoostCalculator.gaugePressure(manifoldAbsolute: 31, barometric: 83)
        #expect(idle == -52)
        #expect(UnitConversion.pressure(kilopascals: idle, to: .psi) < 0) // vacuum is negative

        let positive = BoostCalculator.gaugePressure(manifoldAbsolute: 198, barometric: 83)
        #expect(positive == 115)

        #expect(BoostCalculator.gaugePressure(manifoldAbsolute: 83, barometric: 83) == 0)
    }

    @Test func boostDoesNotAssumeSeaLevel() {
        // Same MAP, different altitude → different boost. Using 101.325 here
        // would under-read by ~18 kPa in Colorado.
        let colorado = BoostCalculator.gaugePressure(manifoldAbsolute: 180, barometric: 83)
        let seaLevel = BoostCalculator.gaugePressure(manifoldAbsolute: 180, barometric: 101)
        #expect(colorado - seaLevel == 18)
    }

    @Test func otherConversions() {
        #expect(UnitConversion.pressure(kilopascals: 250, to: .bar) == 2.5)
        #expect(UnitConversion.temperature(celsius: 90, to: .fahrenheit) == 194)
        #expect(UnitConversion.temperature(celsius: -40, to: .fahrenheit) == -40)
        #expect(abs(UnitConversion.speed(kilometersPerHour: 100, to: .milesPerHour) - 62.137_119) < 1e-5)
        let mpg = UnitConversion.fuelEconomy(litersPer100km: 8, to: .milesPerGallonUS)!
        #expect(abs(mpg - 29.401_823) < 1e-5)
        #expect(UnitConversion.fuelEconomy(litersPer100km: 0, to: .milesPerGallonUS) == nil)
    }

    @Test func presenterFormatsPerUnit() {
        let boost = StandardPIDs.boostChannel
        var presenter = MeasurementPresenter(preferences: .personalDefault)
        #expect(presenter.display(115, for: boost).text == "16.7")
        #expect(presenter.display(115, for: boost).unitSymbol == "PSI")
        #expect(presenter.display(-52, for: boost).text == "-7.5")
        #expect(presenter.display(-0.01, for: boost).text == "0.0") // never "-0.0"

        presenter.preferences.pressure = .kilopascal
        #expect(presenter.display(115, for: boost).text == "115")
        presenter.preferences.pressure = .bar
        #expect(presenter.display(115, for: boost).text == "1.15")

        let coolant = StandardPIDs.definition(for: .coolantTemp)!.channel
        #expect(MeasurementPresenter().display(90, for: coolant).text == "194")
        #expect(MeasurementPresenter().display(90, for: coolant).unitSymbol == "°F")

        let rpm = StandardPIDs.definition(for: .engineRPM)!.channel
        #expect(MeasurementPresenter().display(1726, for: rpm).text == "1726")
    }
}

@Suite("Peak tracking")
struct PeakTrackerTests {
    @Test func boostPeakIgnoresVacuum() {
        var t = PeakTracker(policy: .maximumPositive)
        t.observe(-52)
        #expect(t.peak == nil)
        t.observe(84)
        t.observe(115)
        t.observe(90)
        t.observe(-60)
        #expect(t.peak == 115)
        t.reset()
        #expect(t.peak == nil)
    }

    @Test func maximumAndMinimum() {
        var maxT = PeakTracker(policy: .maximum)
        var minT = PeakTracker(policy: .minimum)
        for v in [3.0, -1, 7, 2] {
            maxT.observe(v)
            minT.observe(v)
        }
        #expect(maxT.peak == 7)
        #expect(minT.peak == -1)
        var none = PeakTracker(policy: .none)
        none.observe(5)
        #expect(none.peak == nil)
    }

    @Test func ignoresNonFinite() {
        var t = PeakTracker(policy: .maximum)
        t.observe(.nan)
        t.observe(.infinity)
        #expect(t.peak == nil)
    }
}
