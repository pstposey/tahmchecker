import CoreBluetooth
import Foundation
import RedlineCore

/// `OBDTransport` over a BLE ELM327 adapter (target: Vgate iCar Pro 2S).
///
/// The adapter's GATT layout is NOT hardcoded (no authoritative source was
/// found; see docs/BLE.md). On open, this transport:
///   1. connects and discovers every service and characteristic,
///   2. logs the full GATT table to the debug console,
///   3. ranks (write, notify) characteristic pairs (`GATTCandidateRanker`),
///   4. verifies a pair by sending `ATI\r` and waiting for a `>`-terminated
///      reply — only a pair that answers like an ELM327 is used,
///   5. remembers the verified pair so the next connection tries it first.
///
/// Concurrency: all CoreBluetooth objects and mutable state are confined to
/// `BLECentral.queue`, where CoreBluetooth delivers callbacks.
final class BLEOBDTransport: NSObject, OBDTransport, BLEConnectionObserver, @unchecked Sendable {
    let identity: TransportIdentity

    private let central: BLECentral
    private let peripheralID: UUID
    private let preferredLink: GATTLinkCandidate?
    private let onLinkVerified: @Sendable (GATTLinkCandidate) -> Void
    private var queue: DispatchQueue { central.queue }
    private let clock = ContinuousClock()

    private enum Mode: Equatable {
        case closed
        case opening
        case probing
        case streaming
    }

    private struct PendingWrite {
        let data: Data
        let completion: CheckedContinuation<Void, Error>?
    }

    // MARK: Queue-confined state
    private var mode: Mode = .closed
    private var generation = 0
    private var closingByUs = false
    private var log: CommLog?
    private var peripheral: CBPeripheral?
    private var gattTable: [GATTCharacteristicInfo] = []
    private var characteristics: [String: CBCharacteristic] = [:]
    private var pendingServiceDiscoveries = 0
    private var discoveryWaiter: CheckedContinuation<[GATTCharacteristicInfo], Error>?
    private var notifyWaiter: CheckedContinuation<Void, Error>?
    /// Per-request tokens: a timer armed for one request must never fail a
    /// later request within the same open().
    private var notifyRequest = 0
    private var notifyTarget: CBCharacteristic?
    private var probeWaiter: CheckedContinuation<String?, Never>?
    private var probeRequest = 0
    /// Generation whose open() was cancelled; new waiters for it bail out.
    private var cancelledGeneration = -1
    private var probeNotifyKey: String?
    private var probeFramer = ELMResponseFramer()
    private var link: GATTLinkCandidate?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeQueue: [PendingWrite] = []
    private var writeInFlight = false
    private var continuation: AsyncStream<TransportEvent>.Continuation?
    private var details = TransportLinkDetails()

    init(central: BLECentral, peripheralID: UUID, name: String, preferredLink: GATTLinkCandidate?,
         onLinkVerified: @escaping @Sendable (GATTLinkCandidate) -> Void) {
        self.central = central
        self.peripheralID = peripheralID
        self.preferredLink = preferredLink
        self.onLinkVerified = onLinkVerified
        self.identity = TransportIdentity(kind: .bluetoothLE, name: name, identifier: peripheralID.uuidString)
        super.init()
    }

    // MARK: OBDTransport

    func open(log: CommLog) async throws -> AsyncStream<TransportEvent> {
        let generation = await onQueue { () -> Int in
            self.generation += 1
            self.log = log
            self.mode = .opening
            self.closingByUs = false
            self.link = nil
            self.writeCharacteristic = nil
            self.notifyCharacteristic = nil
            return self.generation
        }
        return try await withTaskCancellationHandler {
            try await openSteps(log: log)
        } onCancel: {
            self.queue.async { self.abortOpen(generation: generation) }
        }
    }

    private func openSteps(log: CommLog) async throws -> AsyncStream<TransportEvent> {
        try await central.waitUntilPoweredOn(timeout: 5)
        try Task.checkCancellation()
        log.info("BLE: connecting to \(identity.name) [\(peripheralID.uuidString)]")
        try await central.connect(peripheralID, observer: self, timeout: 12)
        log.info("BLE: connected; discovering GATT services")
        do {
            try Task.checkCancellation()
            let table = try await discoverGATT(timeout: 10)
            logGATT(table, to: log)
            let candidates = GATTCandidateRanker.candidates(from: table, preferred: preferredLink)
            if candidates.isEmpty {
                log.error("BLE: no (write, notify) characteristic pair outside standard services")
            }
            for candidate in candidates.prefix(GATTCandidateRanker.maxProbeAttempts) {
                try Task.checkCancellation()
                log.info("BLE: probing \(candidate.summary)")
                if let reply = try await probe(candidate) {
                    log.info("BLE: ELM327 answered — VERIFIED link \(candidate.summary). Reply: \(Self.oneLine(reply))")
                    return await startStreaming(candidate)
                }
                log.warning("BLE: no ELM reply on \(candidate.summary)")
            }
            throw TransportError.noCompatibleCharacteristics
        } catch {
            await onQueue {
                self.mode = .closed
                self.central.disconnectOnQueue(self.peripheralID)
            }
            throw error
        }
    }

    /// Queue-confined. Fails whatever open() step is waiting so cancellation
    /// (source switch, Disconnect) takes effect immediately.
    private func abortOpen(generation: Int) {
        guard generation == self.generation, mode == .opening || mode == .probing else { return }
        cancelledGeneration = generation
        if let w = discoveryWaiter {
            discoveryWaiter = nil
            w.resume(throwing: CancellationError())
        }
        if let w = notifyWaiter {
            notifyWaiter = nil
            notifyTarget = nil
            w.resume(throwing: CancellationError())
        }
        if let w = probeWaiter {
            probeWaiter = nil
            mode = .opening
            w.resume(returning: nil)
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.mode == .streaming, let p = self.peripheral, p.state == .connected,
                      self.writeCharacteristic != nil, let link = self.link else {
                    c.resume(throwing: TransportError.notOpen)
                    return
                }
                let type: CBCharacteristicWriteType = link.writeType == .withoutResponse ? .withoutResponse : .withResponse
                let maxLength = max(p.maximumWriteValueLength(for: type), 20)
                var offset = 0
                var chunks: [Data] = []
                while offset < data.count {
                    let end = min(offset + maxLength, data.count)
                    chunks.append(data.subdata(in: offset..<end))
                    offset = end
                }
                guard !chunks.isEmpty else {
                    c.resume()
                    return
                }
                for (i, chunk) in chunks.enumerated() {
                    self.writeQueue.append(PendingWrite(data: chunk, completion: i == chunks.count - 1 ? c : nil))
                }
                self.pumpWrites()
            }
        }
    }

    func close() async {
        await onQueue {
            self.closingByUs = true
            self.mode = .closed
            self.failWrites(TransportError.notOpen)
            self.continuation?.yield(.closed(nil))
            self.continuation?.finish()
            self.continuation = nil
            self.central.disconnectOnQueue(self.peripheralID)
        }
    }

    func linkDetails() async -> TransportLinkDetails {
        await onQueue { self.details }
    }

    // MARK: Open steps

    private func discoverGATT(timeout: TimeInterval) async throws -> [GATTCharacteristicInfo] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[GATTCharacteristicInfo], Error>) in
            queue.async {
                if self.cancelledGeneration == self.generation {
                    c.resume(throwing: CancellationError())
                    return
                }
                guard let p = self.central.peripheralOnQueue(self.peripheralID), p.state == .connected else {
                    c.resume(throwing: TransportError.disconnected("not connected before GATT discovery"))
                    return
                }
                self.peripheral = p
                p.delegate = self
                self.gattTable = []
                self.characteristics = [:]
                self.discoveryWaiter = c
                p.discoverServices(nil)
                let generation = self.generation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard generation == self.generation, let waiter = self.discoveryWaiter else { return }
                    self.discoveryWaiter = nil
                    waiter.resume(throwing: TransportError.connectFailed("GATT discovery timed out"))
                }
            }
        }
    }

    /// Returns the reply text if the pair answers like an ELM327. Throws when
    /// the link is lost or open() is cancelled: those are not "no reply".
    private func probe(_ candidate: GATTLinkCandidate) async throws -> String? {
        do {
            try await setNotify(true, candidate: candidate)
        } catch let error as TransportError {
            if case .disconnected = error { throw error }
            log?.warning("BLE: could not subscribe to \(candidate.notifyUUID): \(error)")
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log?.warning("BLE: could not subscribe to \(candidate.notifyUUID): \(error)")
            return nil
        }
        let reply = await probeExchange(candidate, timeout: 1.5)
        if reply == nil {
            try Task.checkCancellation()
            let stillConnected = await onQueue { self.mode != .closed && self.peripheral?.state == .connected }
            guard stillConnected else { throw TransportError.disconnected("link lost while probing") }
            try? await setNotify(false, candidate: candidate)
        }
        return reply
    }

    private func setNotify(_ enabled: Bool, candidate: GATTLinkCandidate) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.cancelledGeneration == self.generation {
                    c.resume(throwing: CancellationError())
                    return
                }
                guard let p = self.peripheral, p.state == .connected, self.mode != .closed else {
                    c.resume(throwing: TransportError.disconnected("not connected"))
                    return
                }
                guard let ch = self.characteristics[Self.key(candidate.serviceUUID, candidate.notifyUUID)] else {
                    c.resume(throwing: TransportError.noCompatibleCharacteristics)
                    return
                }
                if ch.isNotifying == enabled {
                    c.resume()
                    return
                }
                self.notifyRequest += 1
                let request = self.notifyRequest
                self.notifyWaiter = c
                self.notifyTarget = ch
                p.setNotifyValue(enabled, for: ch)
                self.queue.asyncAfter(deadline: .now() + 3) {
                    guard request == self.notifyRequest, let waiter = self.notifyWaiter else { return }
                    self.notifyWaiter = nil
                    self.notifyTarget = nil
                    waiter.resume(throwing: BLEError.timedOut(enabled ? "enabling notifications" : "disabling notifications"))
                }
            }
        }
    }

    private func probeExchange(_ candidate: GATTLinkCandidate, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            queue.async {
                guard self.cancelledGeneration != self.generation, self.mode != .closed,
                      let p = self.peripheral, p.state == .connected,
                      let w = self.characteristics[Self.key(candidate.serviceUUID, candidate.writeUUID)] else {
                    c.resume(returning: nil)
                    return
                }
                self.mode = .probing
                self.probeNotifyKey = Self.key(candidate.serviceUUID, candidate.notifyUUID)
                self.probeFramer.reset()
                self.probeWaiter = c
                self.probeRequest += 1
                let request = self.probeRequest
                let type: CBCharacteristicWriteType = candidate.writeType == .withoutResponse ? .withoutResponse : .withResponse
                p.writeValue(Data("ATI\r".utf8), for: w, type: type)
                self.log?.record(.tx, "ATI (probe)")
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard request == self.probeRequest, let waiter = self.probeWaiter else { return }
                    self.probeWaiter = nil
                    if self.mode == .probing { self.mode = .opening }
                    waiter.resume(returning: nil)
                }
            }
        }
    }

    private func startStreaming(_ candidate: GATTLinkCandidate) async -> AsyncStream<TransportEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        await onQueue {
            self.link = candidate
            self.writeCharacteristic = self.characteristics[Self.key(candidate.serviceUUID, candidate.writeUUID)]
            self.notifyCharacteristic = self.characteristics[Self.key(candidate.serviceUUID, candidate.notifyUUID)]
            self.continuation = continuation
            self.mode = .streaming
            self.details = self.makeDetails(candidate)
        }
        onLinkVerified(candidate)
        return stream
    }

    // MARK: Writes (queue)

    private func pumpWrites() {
        guard let p = peripheral, let w = writeCharacteristic, let link else {
            failWrites(TransportError.notOpen)
            return
        }
        while let next = writeQueue.first {
            switch link.writeType {
            case .withoutResponse:
                // Flow control: wait for peripheralIsReady when the buffer is full.
                guard p.canSendWriteWithoutResponse else { return }
                p.writeValue(next.data, for: w, type: .withoutResponse)
                writeQueue.removeFirst()
                next.completion?.resume()
            case .withResponse:
                guard !writeInFlight else { return }
                writeInFlight = true
                p.writeValue(next.data, for: w, type: .withResponse)
                return // continues in didWriteValueFor
            }
        }
    }

    private func failWrites(_ error: Error) {
        let pending = writeQueue
        writeQueue.removeAll()
        writeInFlight = false
        for w in pending { w.completion?.resume(throwing: error) }
    }

    // MARK: Helpers

    /// Runs `body` on the BLE queue and returns its result.
    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            queue.async { c.resume(returning: body()) }
        }
    }

    private static func key(_ service: String, _ characteristic: String) -> String {
        service.uppercased() + "/" + characteristic.uppercased()
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
    }

    static func properties(_ p: CBCharacteristicProperties) -> GATTCharacteristicInfo.Properties {
        var r: GATTCharacteristicInfo.Properties = []
        if p.contains(.read) { r.insert(.read) }
        if p.contains(.write) { r.insert(.write) }
        if p.contains(.writeWithoutResponse) { r.insert(.writeWithoutResponse) }
        if p.contains(.notify) { r.insert(.notify) }
        if p.contains(.indicate) { r.insert(.indicate) }
        return r
    }

    private func logGATT(_ table: [GATTCharacteristicInfo], to log: CommLog) {
        log.info("BLE GATT table (\(table.count) characteristics):")
        for service in Self.servicesInOrder(table) {
            log.info("  service \(service)")
            for ch in table where ch.serviceUUID == service {
                log.info("    \(ch.uuid) [\(ch.properties.shortDescription)]")
            }
        }
    }

    private static func servicesInOrder(_ table: [GATTCharacteristicInfo]) -> [String] {
        var seen: [String] = []
        for ch in table where !seen.contains(ch.serviceUUID) { seen.append(ch.serviceUUID) }
        return seen
    }

    /// Queue-confined.
    private func makeDetails(_ c: GATTLinkCandidate) -> TransportLinkDetails {
        var items: [TransportLinkDetails.Item] = [
            .init("Transport", "Bluetooth LE"),
            .init("Peripheral", "\(identity.name) [\(peripheralID.uuidString)]"),
            .init("Service", c.serviceUUID + " (VERIFIED by ELM probe)"),
            .init("Write characteristic", "\(c.writeUUID) (\(c.writeType.rawValue))"),
            .init("Notify characteristic", c.notifyUUID),
        ]
        if let p = peripheral {
            items.append(.init("Max write (no response)", "\(p.maximumWriteValueLength(for: .withoutResponse)) bytes"))
            items.append(.init("Max write (with response)", "\(p.maximumWriteValueLength(for: .withResponse)) bytes"))
        }
        let table = Self.servicesInOrder(gattTable).map { service in
            service + ": " + gattTable.filter { $0.serviceUUID == service }
                .map { "\($0.uuid)[\($0.properties.shortDescription)]" }.joined(separator: " ")
        }.joined(separator: "\n")
        items.append(.init("GATT table", table))
        return TransportLinkDetails(items: items)
    }

    // MARK: BLEConnectionObserver (queue)

    func peripheralDidDisconnect(error: Error?) {
        let reason = error?.localizedDescription
        log?.warning("BLE: peripheral disconnected\(reason.map { ": \($0)" } ?? "")")
        mode = .closed
        failWrites(TransportError.disconnected(reason))
        if let waiter = discoveryWaiter {
            discoveryWaiter = nil
            waiter.resume(throwing: TransportError.disconnected(reason))
        }
        if let waiter = notifyWaiter {
            notifyWaiter = nil
            notifyTarget = nil
            waiter.resume(throwing: TransportError.disconnected(reason))
        }
        if let waiter = probeWaiter {
            probeWaiter = nil
            waiter.resume(returning: nil)
        }
        if let continuation {
            continuation.yield(.closed(closingByUs ? nil : .disconnected(reason)))
            continuation.finish()
            self.continuation = nil
        }
    }
}

// MARK: - CBPeripheralDelegate (all on `queue`)

extension BLEOBDTransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let waiter = discoveryWaiter else { return }
        if let error {
            discoveryWaiter = nil
            waiter.resume(throwing: TransportError.connectFailed("Service discovery: \(error.localizedDescription)"))
            return
        }
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            discoveryWaiter = nil
            waiter.resume(returning: [])
            return
        }
        pendingServiceDiscoveries = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard discoveryWaiter != nil else { return }
        if let error {
            log?.warning("BLE: characteristic discovery failed for \(service.uuid.uuidString): \(error.localizedDescription)")
        } else {
            for ch in service.characteristics ?? [] {
                let info = GATTCharacteristicInfo(serviceUUID: service.uuid.uuidString, uuid: ch.uuid.uuidString,
                                                  properties: Self.properties(ch.properties))
                gattTable.append(info)
                characteristics[Self.key(info.serviceUUID, info.uuid)] = ch
            }
        }
        pendingServiceDiscoveries -= 1
        if pendingServiceDiscoveries <= 0, let waiter = discoveryWaiter {
            discoveryWaiter = nil
            waiter.resume(returning: gattTable)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        // Only the characteristic this request targets may complete it.
        guard characteristic === notifyTarget, let waiter = notifyWaiter else { return }
        notifyWaiter = nil
        notifyTarget = nil
        if let error {
            waiter.resume(throwing: TransportError.connectFailed("Notify: \(error.localizedDescription)"))
        } else {
            waiter.resume()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let receivedAt = clock.now // timestamp as close to the radio as Swift gets
        guard error == nil, let data = characteristic.value, !data.isEmpty else { return }
        switch mode {
        case .streaming:
            guard characteristic === notifyCharacteristic else { return }
            continuation?.yield(.received(data, at: receivedAt))
        case .probing:
            guard Self.key(characteristic.service?.uuid.uuidString ?? "", characteristic.uuid.uuidString) == probeNotifyKey
            else { return }
            log?.record(.rx, "(probe) " + Self.oneLine(String(decoding: data, as: UTF8.self)))
            if let reply = probeFramer.append(data).first, let waiter = probeWaiter {
                probeWaiter = nil
                mode = .opening
                waiter.resume(returning: reply.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case .opening, .closed:
            return
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard mode == .streaming, writeInFlight, characteristic === writeCharacteristic else {
            if let error { log?.warning("BLE: write error: \(error.localizedDescription)") }
            return
        }
        writeInFlight = false
        guard !writeQueue.isEmpty else { return }
        let done = writeQueue.removeFirst()
        if let error {
            done.completion?.resume(throwing: TransportError.writeFailed(error.localizedDescription))
            failWrites(TransportError.writeFailed(error.localizedDescription))
        } else {
            done.completion?.resume()
            pumpWrites()
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard mode == .streaming else { return }
        pumpWrites()
    }
}
