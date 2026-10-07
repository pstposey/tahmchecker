import CoreBluetooth
import Foundation
import Observation
import RedlineCore

/// Bluetooth radio availability as shown to the user.
enum BluetoothAvailability: Equatable, Sendable {
    /// Bluetooth LE not started yet (it starts on the first scan, so the
    /// MX+ and simulator paths never trigger the permission prompt).
    case notStarted
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn

    var title: String {
        switch self {
        case .notStarted: return "Tap Scan to use Bluetooth LE"
        case .unknown: return "Checking Bluetooth…"
        case .resetting: return "Bluetooth resetting"
        case .unsupported: return "Bluetooth LE unsupported on this device"
        case .unauthorized: return "Bluetooth permission denied — enable it in Settings › Redline"
        case .poweredOff: return "Bluetooth is off"
        case .poweredOn: return "Bluetooth on"
        }
    }

    init(_ state: CBManagerState) {
        switch state {
        case .resetting: self = .resetting
        case .unsupported: self = .unsupported
        case .unauthorized: self = .unauthorized
        case .poweredOff: self = .poweredOff
        case .poweredOn: self = .poweredOn
        default: self = .unknown
        }
    }
}

/// A peripheral seen while scanning (a Sendable copy of CoreBluetooth data).
struct DiscoveredAdapter: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String?
    var rssi: Int
    var advertisedServices: [String]
    var lastSeen: Date

    var displayName: String { name ?? "Unnamed device" }

    /// Name-based hint only — UNVERIFIED. The only real verification is the
    /// ELM probe performed when connecting.
    var looksLikeOBDAdapter: Bool {
        guard let n = name?.lowercased() else { return false }
        return ["obd", "elm", "vlink", "v-link", "vgate", "icar"].contains { n.contains($0) }
    }
}

/// Main-actor Bluetooth state for SwiftUI.
@MainActor
@Observable
final class BluetoothModel {
    var availability: BluetoothAvailability = .notStarted
    var isScanning = false
    var discovered: [DiscoveredAdapter] = []

    func upsert(_ adapter: DiscoveredAdapter) {
        if let i = discovered.firstIndex(where: { $0.id == adapter.id }) {
            discovered[i] = adapter
        } else {
            discovered.append(adapter)
        }
    }
}

enum BLEError: Error, CustomStringConvertible {
    case timedOut(String)
    case cancelled

    var description: String {
        switch self {
        case .timedOut(let what): return "Timed out \(what)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Receives connection events for one peripheral. Called on `BLECentral.queue`.
protocol BLEConnectionObserver: AnyObject, Sendable {
    func peripheralDidDisconnect(error: Error?)
}

/// Owns the app's single `CBCentralManager`.
///
/// Concurrency: every CoreBluetooth object and every mutable property below
/// is confined to `queue` (CoreBluetooth delivers delegate callbacks there).
/// Public methods hop onto the queue. This keeps BLE notifications off the
/// main thread, so a busy UI cannot delay telemetry.
final class BLECentral: NSObject, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.redline.bluetooth", qos: .userInitiated)
    let model: BluetoothModel

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var wantsScan = false
    private var stateWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// One pending connect per peripheral, tagged with its attempt token so a
    /// timer or cancellation from an earlier attempt can't fail a later one.
    private var connectWaiters: [UUID: (token: UUID, continuation: CheckedContinuation<Void, Error>)] = [:]
    /// Attempts cancelled before their queue block ran.
    private var cancelledConnectTokens: Set<UUID> = []
    private var cancelledStateTokens: Set<UUID> = []
    /// Peripherals we asked CoreBluetooth to disconnect whose
    /// didDisconnectPeripheral has not arrived yet. That callback belongs to
    /// the old link and must not fail a new connection to the same adapter.
    private var pendingCancels: Set<UUID> = []
    private var observers: [UUID: BLEConnectionObserver] = [:]

    init(model: BluetoothModel) {
        self.model = model
        super.init()
        // Creating the manager triggers the Bluetooth permission prompt the
        // first time, so BLECentral is created lazily (only when the user
        // chooses a real adapter).
        queue.async {
            self.central = CBCentralManager(delegate: self, queue: self.queue,
                                            options: [CBCentralManagerOptionShowPowerAlertKey: true])
        }
    }

    // MARK: Scanning

    func startScan() {
        queue.async {
            self.wantsScan = true
            self.beginScanIfPossible()
        }
    }

    func stopScan() {
        queue.async {
            self.wantsScan = false
            self.central?.stopScan()
            self.publishScanning(false)
        }
    }

    private func beginScanIfPossible() {
        guard wantsScan, let central, central.state == .poweredOn else { return }
        // No service filter: the adapter's advertised services are unverified.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        publishScanning(true)
    }

    private func publishScanning(_ scanning: Bool) {
        let model = self.model
        Task { @MainActor in model.isScanning = scanning }
    }

    // MARK: Connection primitives (used by BLEOBDTransport)

    func waitUntilPoweredOn(timeout: TimeInterval) async throws {
        let token = UUID()
        try await withTaskCancellationHandler {
            try await waitUntilPoweredOn(token: token, timeout: timeout)
        } onCancel: {
            self.queue.async {
                if let waiter = self.stateWaiters.removeValue(forKey: token) {
                    waiter.resume(throwing: CancellationError())
                } else {
                    self.cancelledStateTokens.insert(token) // not registered yet
                }
            }
        }
    }

    private func waitUntilPoweredOn(token: UUID, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.cancelledStateTokens.remove(token) != nil {
                    c.resume(throwing: CancellationError())
                    return
                }
                switch self.central?.state {
                case .poweredOn?:
                    c.resume()
                case .unauthorized?:
                    c.resume(throwing: TransportError.notAuthorized)
                case .unsupported?:
                    c.resume(throwing: TransportError.unavailable("Bluetooth LE unsupported"))
                default:
                    self.stateWaiters[token] = c
                    self.queue.asyncAfter(deadline: .now() + timeout) {
                        self.stateWaiters.removeValue(forKey: token)?.resume(
                            throwing: TransportError.unavailable("Bluetooth is not powered on"))
                    }
                }
            }
        }
    }

    /// Must be called on `queue`.
    func peripheralOnQueue(_ id: UUID) -> CBPeripheral? {
        if let p = peripherals[id] { return p }
        // Previously seen peripherals can be retrieved without scanning.
        if let p = central?.retrievePeripherals(withIdentifiers: [id]).first {
            peripherals[id] = p
            return p
        }
        return nil
    }

    func connect(_ id: UUID, observer: BLEConnectionObserver, timeout: TimeInterval) async throws {
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                queue.async {
                    if self.cancelledConnectTokens.remove(token) != nil {
                        c.resume(throwing: BLEError.cancelled)
                        return
                    }
                    guard let central = self.central, let p = self.peripheralOnQueue(id) else {
                        c.resume(throwing: TransportError.peripheralNotFound)
                        return
                    }
                    self.observers[id] = observer
                    let cancelInFlight = self.pendingCancels.contains(id)
                    if p.state == .connected, !cancelInFlight {
                        c.resume()
                        return
                    }
                    self.connectWaiters.removeValue(forKey: id)?.continuation.resume(throwing: BLEError.cancelled)
                    self.connectWaiters[id] = (token, c)
                    // If our own disconnect is still completing, connect once
                    // its didDisconnectPeripheral arrives (see that callback).
                    if !cancelInFlight { central.connect(p, options: nil) }
                    self.queue.asyncAfter(deadline: .now() + timeout) {
                        guard self.connectWaiters[id]?.token == token,
                              let waiter = self.connectWaiters.removeValue(forKey: id) else { return }
                        if let p = self.peripherals[id] { self.central?.cancelPeripheralConnection(p) }
                        waiter.continuation.resume(throwing: TransportError.connectTimedOut)
                    }
                }
            }
        } onCancel: {
            self.queue.async {
                guard self.connectWaiters[id]?.token == token,
                      let waiter = self.connectWaiters.removeValue(forKey: id) else {
                    // Not registered yet: make the queue block bail out.
                    self.cancelledConnectTokens.insert(token)
                    return
                }
                if let p = self.peripherals[id] { self.central?.cancelPeripheralConnection(p) }
                waiter.continuation.resume(throwing: BLEError.cancelled)
            }
        }
    }

    /// Must be called on `queue`.
    func disconnectOnQueue(_ id: UUID) {
        observers.removeValue(forKey: id)
        guard let p = peripherals[id] else { return }
        if p.state == .connected || p.state == .disconnecting {
            pendingCancels.insert(id)
        }
        central?.cancelPeripheralConnection(p)
    }
}

// MARK: - CBCentralManagerDelegate (all on `queue`)

extension BLECentral: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let availability = BluetoothAvailability(central.state)
        let model = self.model
        Task { @MainActor in model.availability = availability }

        switch central.state {
        case .poweredOn:
            for (_, waiter) in stateWaiters { waiter.resume() }
            stateWaiters.removeAll()
            beginScanIfPossible()
            return
        case .unauthorized:
            for (_, waiter) in stateWaiters { waiter.resume(throwing: TransportError.notAuthorized) }
            stateWaiters.removeAll()
        case .unsupported:
            for (_, waiter) in stateWaiters { waiter.resume(throwing: TransportError.unavailable("Bluetooth LE unsupported")) }
            stateWaiters.removeAll()
        default:
            break
        }
        publishScanning(false)

        // Below poweredOn every connection is gone, and CoreBluetooth does not
        // promise a didDisconnectPeripheral for each, so report them here.
        let reason = availability.title
        let waiters = connectWaiters
        connectWaiters.removeAll()
        for (_, w) in waiters { w.continuation.resume(throwing: TransportError.disconnected(reason)) }
        pendingCancels.removeAll()
        let currentObservers = observers
        observers.removeAll()
        let error = NSError(domain: "Redline.Bluetooth", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        for (_, o) in currentObservers { o.peripheralDidDisconnect(error: error) }
        // Below poweredOff, every CBPeripheral from this manager is invalid and
        // must be retrieved again (CoreBluetooth header documentation).
        if central.state.rawValue < CBManagerState.poweredOff.rawValue {
            peripherals.removeAll()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        let adapter = DiscoveredAdapter(
            id: peripheral.identifier,
            name: peripheral.name ?? localName,
            rssi: RSSI.intValue,
            advertisedServices: services,
            lastSeen: Date()
        )
        let model = self.model
        Task { @MainActor in model.upsert(adapter) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectWaiters.removeValue(forKey: peripheral.identifier)?.continuation.resume()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectWaiters.removeValue(forKey: peripheral.identifier)?.continuation.resume(
            throwing: TransportError.connectFailed(error?.localizedDescription ?? "unknown error"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        if pendingCancels.remove(id) != nil {
            // Completion of a disconnect we requested for a previous link.
            // A new connect may be waiting for it.
            if connectWaiters[id] != nil { central.connect(peripheral, options: nil) }
            return
        }
        connectWaiters.removeValue(forKey: id)?.continuation.resume(
            throwing: TransportError.disconnected(error?.localizedDescription))
        observers[id]?.peripheralDidDisconnect(error: error)
    }
}
