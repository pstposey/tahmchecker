import ExternalAccessory
import Foundation
import Observation
import RedlineCore

/// MFi accessories (OBDLink MX+) as shown on the Connect screen.
@MainActor
@Observable
final class AccessoryModel {
    /// Every accessory iOS reports as connected and available to Redline.
    var connected: [AccessoryDescriptor] = []
    /// `UISupportedExternalAccessoryProtocols` from Info.plist.
    var declaredProtocols: [String] = []

    func supportedProtocol(of accessory: AccessoryDescriptor) -> String? {
        AccessorySelector.supportedProtocol(of: accessory, declared: declaredProtocols)
    }
}

/// Owns every External Accessory framework object.
///
/// The MX+ is a Bluetooth Classic MFi accessory: iOS pairs and connects it
/// (Settings › Bluetooth), and an app can only open a session to an
/// accessory that is already connected — there is no app-initiated connect.
///
/// Main-actor confined: EA posts its notifications and calls delegates on
/// the main thread, and `EAAccessory` / `EASession` are not Sendable. Only
/// `AccessoryDescriptor` snapshots leave this class; stream I/O happens on
/// the session's own thread (`EAStreamSession`). Created lazily after
/// launch: Apple advises against touching EA during app initialization.
@MainActor
final class ExternalAccessoryCenter {
    let model: AccessoryModel
    private var observers: [NSObjectProtocol] = []
    private var changeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var liveSessions: [WeakSession] = []

    private struct WeakSession {
        weak var session: EAStreamSession?
    }

    static var declaredProtocols: [String] {
        Bundle.main.object(forInfoDictionaryKey: "UISupportedExternalAccessoryProtocols") as? [String] ?? []
    }

    init(model: AccessoryModel) {
        self.model = model
        model.declaredProtocols = Self.declaredProtocols
        // Once for the app's lifetime; the notifications are not sent otherwise.
        EAAccessoryManager.shared().registerForLocalNotifications()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .EAAccessoryDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.accessoriesChanged(disconnected: nil) }
        })
        observers.append(center.addObserver(forName: .EAAccessoryDidDisconnect, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[EAAccessoryKey] as? EAAccessory)?.connectionID
            MainActor.assumeIsolated { self?.accessoriesChanged(disconnected: id) }
        })
        refresh()
    }

    /// Re-reads the connected list (also used on returning to the
    /// foreground: notifications are queued and coalesced while suspended).
    func refresh() {
        model.connected = EAAccessoryManager.shared().connectedAccessories.map(Self.describe)
    }

    nonisolated static func describe(_ a: EAAccessory) -> AccessoryDescriptor {
        AccessoryDescriptor(connectionID: a.connectionID, name: a.name, manufacturer: a.manufacturer,
                            modelNumber: a.modelNumber, serialNumber: a.serialNumber,
                            firmwareRevision: a.firmwareRevision, hardwareRevision: a.hardwareRevision,
                            protocolStrings: a.protocolStrings)
    }

    private func accessoriesChanged(disconnected connectionID: Int?) {
        refresh()
        if let connectionID {
            liveSessions.removeAll { $0.session == nil }
            for entry in liveSessions where entry.session?.connectionID == connectionID {
                entry.session?.accessoryDisconnected()
            }
        }
        let waiters = changeWaiters
        changeWaiters.removeAll()
        for (_, w) in waiters { w.resume() }
    }

    /// Waits (up to `timeout`) until the target accessory is connected and
    /// advertises a protocol Redline declares, then opens an `EASession`.
    func openSession(target: AccessoryTarget, timeout: Duration, log: CommLog) async throws -> EAStreamSession {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var lastReport: String?
        while true {
            try Task.checkCancellation()
            let accessories = EAAccessoryManager.shared().connectedAccessories
            let snapshots = accessories.map(Self.describe)
            model.connected = snapshots
            switch AccessorySelector.choose(target: target, from: snapshots, declared: model.declaredProtocols) {
            case .success(let choice):
                if let accessory = accessories.first(where: { $0.connectionID == choice.accessory.connectionID }) {
                    log.info("MFi: opening a session to \(choice.accessory.displayName) with protocol \(choice.protocolString)")
                    guard let session = try await makeSession(accessory, choice.protocolString, log: log) else {
                        throw TransportError.connectFailed(
                            "iOS refused a session with \(choice.accessory.displayName) (\(choice.protocolString)). "
                            + "Close other OBD apps (e.g. OBDLink) that may be using the adapter, then try again")
                    }
                    let stream = EAStreamSession(session: session, accessory: choice.accessory,
                                                 protocolString: choice.protocolString, declared: model.declaredProtocols)
                    liveSessions.removeAll { $0.session == nil }
                    liveSessions.append(WeakSession(session: stream))
                    return stream
                }
                guard clock.now < deadline else { throw TransportError.unavailable("The accessory disconnected while Redline was opening it") }
            case .failure(let failure):
                let report = failure.description
                if report != lastReport {
                    lastReport = report
                    log.info("MFi: \(report)")
                    for a in snapshots {
                        log.info("MFi: connected accessory \(a.displayName) — \(a.manufacturer) \(a.modelNumber), "
                                 + "protocols [\(a.protocolStrings.joined(separator: ", "))]")
                    }
                    log.info("MFi: Redline declares [\(model.declaredProtocols.joined(separator: ", "))]")
                }
                guard clock.now < deadline else { throw TransportError.unavailable(report) }
            }
            await waitForChange(until: deadline)
        }
    }

    /// Opens the `EASession`. Only one session per accessory and protocol can
    /// exist; our previous one (e.g. just closed for a reconnect) is released
    /// on its stream thread a moment after `close()`, so while one of ours
    /// is still alive for this accessory, wait briefly and retry instead of
    /// blaming another app.
    private func makeSession(_ accessory: EAAccessory, _ protocolString: String, log: CommLog) async throws -> EASession? {
        for attempt in 0..<20 {
            if let session = EASession(accessory: accessory, forProtocol: protocolString) { return session }
            liveSessions.removeAll { $0.session == nil }
            guard liveSessions.contains(where: { $0.session?.connectionID == accessory.connectionID }) else { return nil }
            if attempt == 0 { log.info("MFi: previous session still closing; retrying") }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// Returns on the next connect/disconnect notification, at `deadline`,
    /// or when the task is cancelled.
    private func waitForChange(until deadline: ContinuousClock.Instant) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                changeWaiters[id] = c
                Task { @MainActor [weak self] in
                    try? await ContinuousClock().sleep(until: deadline)
                    self?.resumeWaiter(id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeWaiter(id) }
        }
    }

    private func resumeWaiter(_ id: UUID) {
        changeWaiters.removeValue(forKey: id)?.resume()
    }
}

/// `AccessoryStreamConnector` for the MX+ (or any MFi accessory speaking a
/// declared protocol).
struct ExternalAccessoryConnector: AccessoryStreamConnector {
    let center: ExternalAccessoryCenter
    let target: AccessoryTarget

    func connect(timeout: Duration, log: CommLog) async throws -> any AccessoryStreamSession {
        try await center.openSession(target: target, timeout: timeout, log: log)
    }
}
