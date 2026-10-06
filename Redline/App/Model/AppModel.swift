import Foundation
import Observation
import RedlineCore
import SwiftUI

/// Composition root: owns the telemetry engine and decides which transport
/// feeds it. Views never talk to transports or the ELM session directly.
@MainActor
@Observable
final class AppModel {
    let engine: TelemetryEngine
    let bluetooth = BluetoothModel()

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            presenter = MeasurementPresenter(preferences: settings.units)
            if settings.pollingPreset != engine.pollingPreset { engine.pollingPreset = settings.pollingPreset }
            if settings.elmOptions != engine.options { engine.options = settings.elmOptions }
            if settings.simulationScenario != oldValue.simulationScenario {
                simulatedVehicle?.setScenario(settings.simulationScenario)
            }
        }
    }

    private(set) var presenter: MeasurementPresenter
    /// Present only while the simulator is the active source.
    private(set) var simulatedVehicle: SimulatedVehicle?

    @ObservationIgnored private var bleCentral: BLECentral?
    @ObservationIgnored private var launched = false

    var isSimulationActive: Bool { simulatedVehicle != nil }

    var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Redline \(version) (\(build))"
    }

    init() {
        let settings = AppSettings.load()
        self.settings = settings
        self.presenter = MeasurementPresenter(preferences: settings.units)
        self.engine = TelemetryEngine(options: settings.elmOptions, pollingPreset: settings.pollingPreset)
    }

    /// Called once at launch.
    func launch() {
        guard !launched else { return }
        launched = true
        switch settings.dataSource {
        case .simulation:
            startSimulation()
        case .vehicle:
            if settings.autoConnect, settings.rememberedAdapterID != nil {
                connectRememberedAdapter()
            }
        }
    }

    // MARK: Sources

    func startSimulation() {
        settings.dataSource = .simulation
        let vehicle = SimulatedVehicle(scenario: settings.simulationScenario)
        simulatedVehicle = vehicle
        engine.start(transport: SimulatedELM327Transport(vehicle: vehicle))
    }

    func connect(to adapter: DiscoveredAdapter) {
        let central = ensureBLE()
        central.stopScan()
        if settings.rememberedAdapterID != adapter.id {
            settings.verifiedLink = nil
        }
        settings.rememberedAdapterID = adapter.id
        settings.rememberedAdapterName = adapter.displayName
        settings.dataSource = .vehicle
        startBLE(central: central, id: adapter.id, name: adapter.displayName)
    }

    func connectRememberedAdapter() {
        guard let id = settings.rememberedAdapterID else { return }
        settings.dataSource = .vehicle
        startBLE(central: ensureBLE(), id: id, name: settings.rememberedAdapterName ?? "OBD adapter")
    }

    func forgetAdapter() {
        settings.rememberedAdapterID = nil
        settings.rememberedAdapterName = nil
        settings.verifiedLink = nil
    }

    func disconnect() {
        simulatedVehicle = nil
        Task { await engine.stop() }
    }

    /// Reconnects the current source (applies changed ELM options).
    func reconnect() {
        if isSimulationActive {
            startSimulation()
        } else {
            connectRememberedAdapter()
        }
    }

    func startScan() { ensureBLE().startScan() }
    func stopScan() { bleCentral?.stopScan() }

    /// Bluetooth is only initialized when needed, so simulation-only use never
    /// triggers the Bluetooth permission prompt.
    func prepareBluetooth() { _ = ensureBLE() }

    private func ensureBLE() -> BLECentral {
        if let bleCentral { return bleCentral }
        let central = BLECentral(model: bluetooth)
        bleCentral = central
        return central
    }

    private func startBLE(central: BLECentral, id: UUID, name: String) {
        simulatedVehicle = nil
        let transport = BLEOBDTransport(
            central: central, peripheralID: id, name: name, preferredLink: settings.verifiedLink,
            onLinkVerified: { [weak self] link in
                Task { @MainActor in self?.settings.verifiedLink = link }
            }
        )
        engine.start(transport: transport)
    }

    // MARK: App lifecycle

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            engine.setPaused(false)
        case .background:
            // Without a Bluetooth background mode iOS suspends the app; stop
            // requesting so no command is left half-finished at suspension.
            engine.setPaused(true)
        default:
            break
        }
    }
}
