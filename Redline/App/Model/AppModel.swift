import Foundation
import Observation
import RedlineCore
import SwiftUI
import UIKit

/// Composition root: owns the telemetry engine and decides which transport
/// feeds it. Views never talk to transports or the ELM session directly.
@MainActor
@Observable
final class AppModel {
    let engine: TelemetryEngine
    let bluetooth = BluetoothModel()
    let accessories = AccessoryModel()

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
    @ObservationIgnored private var accessoryCenter: ExternalAccessoryCenter?
    @ObservationIgnored private var launched = false
    /// The MFi accessory being used now (nil for BLE / simulator / idle).
    @ObservationIgnored private var activeAccessory: RememberedAccessory?
    /// The MFi session closed because the app went to the background; this
    /// accessory is reopened when the app returns (even if it was forgotten
    /// in the meantime — the user didn't disconnect it).
    @ObservationIgnored private var resumeAccessory: RememberedAccessory?

    var isSimulationActive: Bool { simulatedVehicle != nil }

    /// App, iOS and device versions (for the debug report: EA behaviour
    /// differs between iOS releases).
    var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "Redline \(version) (\(build)) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion) · \(machine)"
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
            if settings.autoConnect, settings.rememberedAdapter != nil {
                connectRememberedAdapter()
            }
        }
    }

    // MARK: Sources

    func startSimulation() {
        activeAccessory = nil
        resumeAccessory = nil
        settings.dataSource = .simulation
        let vehicle = SimulatedVehicle(scenario: settings.simulationScenario)
        simulatedVehicle = vehicle
        engine.start(transport: SimulatedELM327Transport(vehicle: vehicle))
    }

    /// Connects to a BLE adapter found by scanning (Vgate iCar Pro 2S).
    func connect(to adapter: DiscoveredAdapter) {
        let central = ensureBLE()
        central.stopScan()
        var link: GATTLinkCandidate?
        if case .bluetoothLE(let id, _, let verified) = settings.rememberedAdapter, id == adapter.id {
            link = verified // keep the verified GATT pair only for the same adapter
        }
        settings.rememberedAdapter = .bluetoothLE(id: adapter.id, name: adapter.displayName, verifiedLink: link)
        settings.dataSource = .vehicle
        startBLE(central: central, id: adapter.id, name: adapter.displayName, link: link)
    }

    /// Connects to an MFi accessory iOS already has connected (OBDLink MX+).
    func connect(toAccessory accessory: AccessoryDescriptor) {
        bleCentral?.stopScan()
        settings.rememberedAdapter = .externalAccessory(accessory.remembered)
        settings.dataSource = .vehicle
        startAccessory(accessory.remembered)
    }

    func connectRememberedAdapter() {
        settings.dataSource = .vehicle
        switch settings.rememberedAdapter {
        case .bluetoothLE(let id, let name, let link)?:
            startBLE(central: ensureBLE(), id: id, name: name, link: link)
        case .externalAccessory(let accessory)?:
            startAccessory(accessory)
        case nil:
            return
        }
    }

    func forgetAdapter() {
        settings.rememberedAdapter = nil
    }

    func disconnect() {
        simulatedVehicle = nil
        activeAccessory = nil
        resumeAccessory = nil
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

    /// Bluetooth LE is only initialized when needed, so simulation-only or
    /// MX+-only use never triggers the Bluetooth permission prompt.
    func prepareBluetooth() { _ = ensureBLE() }

    /// Starts watching for MFi accessories (no permission prompt involved).
    func prepareAccessories() { _ = ensureAccessoryCenter() }
    func refreshAccessories() { ensureAccessoryCenter().refresh() }

    private func ensureBLE() -> BLECentral {
        if let bleCentral { return bleCentral }
        let central = BLECentral(model: bluetooth)
        bleCentral = central
        return central
    }

    private func ensureAccessoryCenter() -> ExternalAccessoryCenter {
        if let accessoryCenter { return accessoryCenter }
        let center = ExternalAccessoryCenter(model: accessories)
        accessoryCenter = center
        return center
    }

    private func startBLE(central: BLECentral, id: UUID, name: String, link: GATTLinkCandidate?) {
        simulatedVehicle = nil
        activeAccessory = nil
        resumeAccessory = nil
        let transport = BLEOBDTransport(
            central: central, peripheralID: id, name: name, preferredLink: link,
            onLinkVerified: { [weak self] link in
                Task { @MainActor in
                    // A superseded transport must not stamp its link onto
                    // whichever adapter is remembered now.
                    guard let self, case .bluetoothLE(let rid, let rname, _) = self.settings.rememberedAdapter,
                          rid == id else { return }
                    self.settings.rememberedAdapter = .bluetoothLE(id: rid, name: rname, verifiedLink: link)
                }
            }
        )
        engine.start(transport: transport)
    }

    private func startAccessory(_ accessory: RememberedAccessory) {
        simulatedVehicle = nil
        activeAccessory = accessory
        resumeAccessory = nil
        let connector = ExternalAccessoryConnector(center: ensureAccessoryCenter(), target: .remembered(accessory))
        let identity = TransportIdentity(
            kind: .externalAccessory,
            name: accessory.name.isEmpty ? "MFi accessory" : accessory.name,
            identifier: accessory.serialNumber.isEmpty ? accessory.modelNumber : accessory.serialNumber)
        // OBDLink: the adapter can take up to about a minute to appear after
        // it is plugged in; the engine keeps retrying after each timeout.
        engine.start(transport: AccessoryStreamTransport(identity: identity, connector: connector,
                                                         connectTimeout: .seconds(30), openTimeout: .seconds(5)))
    }

    // MARK: App lifecycle

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            engine.setPaused(false)
            // Accessory notifications are queued and coalesced while the app
            // is suspended: re-read the list instead of trusting them.
            accessoryCenter?.refresh()
            if let accessory = resumeAccessory {
                settings.dataSource = .vehicle
                startAccessory(accessory)
            } else {
                engine.retryNow()
            }
        case .background:
            if let accessory = activeAccessory, engine.state != .idle, !engine.isStopping {
                // Without the external-accessory background mode, iOS ends
                // accessory sessions when the app is backgrounded. Close ours
                // cleanly now and open a fresh one on return.
                resumeAccessory = accessory
                Task { await engine.stop() }
            } else {
                // BLE: without a Bluetooth background mode iOS suspends the
                // app; stop requesting so no command is left half-finished.
                engine.setPaused(true)
            }
        default:
            break
        }
    }
}
