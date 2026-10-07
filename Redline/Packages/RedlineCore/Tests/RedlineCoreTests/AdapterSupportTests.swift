import Foundation
import Testing
@testable import RedlineCore

/// Adapter selection and identification: the transport-independent logic
/// behind supporting both the Vgate iCar Pro 2S (BLE) and the OBDLink MX+
/// (MFi / External Accessory). Accessory snapshots are mocks; nothing here
/// claims to know what the real MX+ reports (see HARDWARE_TEST.md).
@Suite("Adapters: MFi accessory selection")
struct AccessorySelectionTests {
    static let declared = ["com.obdlink", "com.scantool.stnobd"]

    static func accessory(_ id: Int, name: String = "Mock MFi adapter", serial: String = "SN1",
                          model: String = "M1", protocols: [String]) -> AccessoryDescriptor {
        AccessoryDescriptor(connectionID: id, name: name, manufacturer: "Mock Co", modelNumber: model,
                            serialNumber: serial, firmwareRevision: "1.0", hardwareRevision: "A",
                            protocolStrings: protocols)
    }

    @Test func picksTheAccessoryAndTheMostPreferredDeclaredProtocol() throws {
        let a = Self.accessory(7, protocols: ["com.scantool.stnobd", "com.obdlink"])
        let choice = try AccessorySelector.choose(target: .any, from: [a], declared: Self.declared).get()
        #expect(choice.accessory == a)
        #expect(choice.protocolString == "com.obdlink") // declared order is preference
    }

    @Test func reportsWhyNothingCanBeOpened() {
        #expect(AccessorySelector.choose(target: .any, from: [], declared: Self.declared)
                == .failure(.noAccessoryConnected))
        // Protocols are empty until iOS finishes MFi authentication: wait.
        #expect(AccessorySelector.choose(target: .any, from: [Self.accessory(1, protocols: [])], declared: Self.declared)
                == .failure(.accessoryNotReady))
        let headphones = Self.accessory(2, name: "Headphones", protocols: ["com.example.audio"])
        #expect(AccessorySelector.choose(target: .any, from: [headphones], declared: Self.declared)
                == .failure(.noSupportedProtocol([headphones])))
        #expect(AccessorySelector.choose(target: .any, from: [Self.accessory(3, protocols: ["com.obdlink"])], declared: [])
                == .failure(.noDeclaredProtocols))
    }

    @Test func protocolMatchingIsExactAndCaseSensitive() {
        let a = Self.accessory(1, protocols: ["com.OBDLink", "com.obdlink.extra"])
        #expect(AccessorySelector.supportedProtocol(of: a, declared: Self.declared) == nil)
    }

    @Test func rememberedAdapterIsFoundAgainAfterReconnect() throws {
        // connectionID changes on every reconnect; the serial number doesn't.
        let before = Self.accessory(10, serial: "ABC123", protocols: ["com.obdlink"])
        let remembered = before.remembered
        let other = Self.accessory(11, name: "Other adapter", serial: "ZZZ999", protocols: ["com.obdlink"])
        let after = Self.accessory(42, serial: "ABC123", protocols: ["com.obdlink"])
        let choice = try AccessorySelector.choose(target: .remembered(remembered), from: [other, after],
                                                  declared: Self.declared).get()
        #expect(choice.accessory.connectionID == 42)
        #expect(AccessorySelector.choose(target: .remembered(remembered), from: [other], declared: Self.declared)
                == .failure(.targetNotConnected))
    }

    @Test func withoutASerialNumberNameManufacturerAndModelMustMatch() {
        let a = Self.accessory(1, name: "OBD", serial: "", model: "X", protocols: ["com.obdlink"])
        #expect(a.remembered.matches(Self.accessory(2, name: "OBD", serial: "", model: "X", protocols: [])))
        #expect(!a.remembered.matches(Self.accessory(3, name: "OBD", serial: "", model: "Y", protocols: [])))
        #expect(!a.remembered.matches(Self.accessory(4, name: "OBD", serial: "S", model: "X", protocols: [])))
    }

    @Test func aSpecificConnectionCanBeTargeted() throws {
        let a = Self.accessory(1, serial: "A", protocols: ["com.obdlink"])
        let b = Self.accessory(2, serial: "B", protocols: ["com.obdlink"])
        #expect(try AccessorySelector.choose(target: .connection(2), from: [a, b], declared: Self.declared).get().accessory == b)
        #expect(AccessorySelector.choose(target: .connection(3), from: [a, b], declared: Self.declared)
                == .failure(.targetNotConnected))
    }

    @Test func detailItemsCarryEverythingTheHardwareTestNeeds() {
        let keys = Self.accessory(1, protocols: ["com.obdlink"]).detailItems.map(\.key)
        #expect(keys == ["Accessory name", "Manufacturer", "Model", "Serial number", "Firmware", "Hardware",
                         "Connection ID", "Advertised protocols"])
    }
}

@Suite("Adapters: remembered adapter and identification")
struct AdapterCatalogTests {
    @Test func rememberedAdapterRoundTripsForBothTransports() throws {
        let link = GATTLinkCandidate(serviceUUID: "FFF0", writeUUID: "FFF2", notifyUUID: "FFF1", writeType: .withResponse)
        let values: [RememberedAdapter] = [
            .bluetoothLE(id: UUID(), name: "IOS-Vlink", verifiedLink: link),
            .bluetoothLE(id: UUID(), name: "Vgate", verifiedLink: nil),
            .externalAccessory(RememberedAccessory(name: "OBDLink MX+", manufacturer: "Mock", modelNumber: "M",
                                                   serialNumber: "S")),
        ]
        for v in values {
            let decoded = try JSONDecoder().decode(RememberedAdapter.self, from: JSONEncoder().encode(v))
            #expect(decoded == v)
        }
        #expect(values.map(\.transport) == [.bluetoothLE, .bluetoothLE, .externalAccessory])
    }

    @Test func settingsFromBeforeMXPlusSupportMigrateToABLEAdapter() {
        let id = UUID()
        let link = GATTLinkCandidate(serviceUUID: "FFF0", writeUUID: "FFF2", notifyUUID: "FFF1", writeType: .withoutResponse)
        #expect(RememberedAdapter.migrating(legacyID: id, legacyName: "Vgate", legacyLink: link)
                == .bluetoothLE(id: id, name: "Vgate", verifiedLink: link))
        #expect(RememberedAdapter.migrating(legacyID: nil, legacyName: "Vgate", legacyLink: link) == nil)
    }

    @Test func supportedAdaptersMapToTheirTransports() {
        #expect(SupportedAdapter.vgateICarPro2S.transport == .bluetoothLE)
        #expect(SupportedAdapter.obdLinkMXPlus.transport == .externalAccessory)
        #expect(TransportKind.externalAccessory.title.contains("External Accessory"))
        #expect(TransportKind.bluetoothLE.title.contains("Bluetooth LE"))
    }

    @Test func identificationIsNameBasedAndShowsItsEvidence() {
        let mx = AdapterIdentifier.identify(
            identity: TransportIdentity(kind: .externalAccessory, name: "OBDLink MX+", identifier: "x"),
            linkDetails: TransportLinkDetails(items: [.init("Manufacturer", "OBD Solutions")]), adapterInfo: nil)
        #expect(mx.adapter == .obdLinkMXPlus)
        #expect(mx.summary.contains("MFi accessory"))

        let unknownMFi = AdapterIdentifier.identify(
            identity: TransportIdentity(kind: .externalAccessory, name: "Some Dongle", identifier: "x"),
            linkDetails: nil, adapterInfo: nil)
        #expect(unknownMFi.adapter == nil)

        let vgate = AdapterIdentifier.identify(
            identity: TransportIdentity(kind: .bluetoothLE, name: "IOS-Vlink", identifier: "x"),
            linkDetails: nil, adapterInfo: nil)
        #expect(vgate.adapter == .vgateICarPro2S)

        let sim = AdapterIdentifier.identify(
            identity: TransportIdentity(kind: .simulated, name: "Redline Simulator", identifier: "simulator"),
            linkDetails: nil, adapterInfo: nil)
        #expect(sim.adapter == nil && sim.summary.contains("simulator"))
    }
}

@MainActor
@Suite("Adapters: engine retry and policy behaviour")
struct AdapterEngineTests {
    final class AlwaysFailingTransport: OBDTransport, @unchecked Sendable {
        let opens = Locked(0)
        let identity = TransportIdentity(kind: .externalAccessory, name: "Absent MX+", identifier: "x")
        func open(log: CommLog) async throws -> AsyncStream<TransportEvent> {
            opens.withLock { $0 += 1 }
            throw TransportError.unavailable("No MFi accessory is connected (test)")
        }
        func write(_ data: Data) async throws { throw TransportError.notOpen }
        func close() async {}
        func linkDetails() async -> TransportLinkDetails { TransportLinkDetails() }
    }

    /// Returning to the foreground (or tapping Retry) must not wait out the
    /// reconnect backoff.
    @Test func retryNowCutsTheReconnectWaitShort() async throws {
        let engine = TelemetryEngine(pollingPreset: .rpmOnly)
        let t = AlwaysFailingTransport()
        engine.start(transport: t)
        try await waitUntil(seconds: 5) { if case .reconnecting = engine.state { return true } else { return false } }
        // Backoff after attempt 1 is 2 s; retryNow must start attempt 2 at once.
        let start = ContinuousClock().now
        engine.retryNow()
        try await waitUntil(seconds: 1.5) { t.opens.withLock { $0 } >= 2 }
        #expect(ContinuousClock().now - start < .seconds(1.5))
        await engine.stop()
    }

    /// Review finding: the counter used to survive stop()/start(), so a
    /// fresh connection could begin at the 30 s retry interval.
    @Test func vehicleRetryBackoffRestartsForEachConnection() async throws {
        let ignitionOff: (String) -> ScriptedTransport.Reply = { cmd in
            switch cmd {
            case "ATZ": return .text("\r\rELM327 v1.5\r\r>", after: .milliseconds(2))
            case "ATI": return .text("ELM327 v1.5\r\r>", after: .milliseconds(2))
            case "AT@1": return .text("OBDII to RS232 Interpreter\r\r>", after: .milliseconds(2))
            case "ATRV": return .text("12.6V\r\r>", after: .milliseconds(2))
            case "ATDPN": return .text("0\r\r>", after: .milliseconds(2))
            case "0100": return .text("NO DATA\r\r>", after: .milliseconds(2))
            default: return .text("OK\r\r>", after: .milliseconds(2))
            }
        }
        let engine = TelemetryEngine(pollingPreset: .rpmOnly)
        engine.start(transport: ScriptedTransport(script: ignitionOff))
        try await waitUntil(seconds: 10) { engine.unansweredVehicleProbes >= 1 }
        engine.unansweredVehicleProbes = 20 // as if the ignition had been off for minutes
        await engine.stop()
        #expect(engine.state == .idle)
        engine.start(transport: ScriptedTransport(script: ignitionOff))
        try await waitUntil(seconds: 10) {
            if case .vehicleUnavailable = engine.state { return true }
            return false
        }
        #expect(engine.unansweredVehicleProbes == 1)
        if case .vehicleUnavailable(let why) = engine.state {
            #expect(why.contains("Retrying in 3 s"), "\(why)")
        } else {
            Issue.record("expected vehicleUnavailable, got \(engine.state)")
        }
        await engine.stop()
    }

    @Test func vehicleRetriesSlowDownWhileTheVehicleStaysSilent() {
        #expect((1...5).map { TelemetryEngine.vehicleRetryDelay($0) }.allSatisfy { $0 == .seconds(3) })
        #expect(TelemetryEngine.vehicleRetryDelay(6) == .seconds(10))
        #expect(TelemetryEngine.vehicleRetryDelay(100) == .seconds(30))
    }

    /// The poller's own guard: even when an ECU supports PID 04 and the
    /// caller asks for it, `0104` is never scheduled (the session would
    /// refuse it, and a refused poll must not tear the link down).
    @Test func pollerNeverSchedulesAPolicyRefusedPID() async throws {
        let session = ELM327Session(transport: SimulatedELM327Transport(), log: CommLog())
        var support = PIDSupportMap()
        support.record(base: 0x00, bitmask: [0x18, 0x18, 0x00, 0x00], from: .can11(0x7E8)) // PIDs 04, 05, 0C, 0D
        let worker = PollingWorker(session: session, monitor: PerformanceMonitor(),
                                   context: .init(info: AdapterInfo(), support: support, options: ELMOptions()))
        let load = try #require(StandardPIDs.definition(for: .engineLoad))
        let rpm = try #require(StandardPIDs.definition(for: .engineRPM))
        #expect(support.isSupported(0x04) && support.isSupported(0x0C))
        #expect(await worker.setPolled([load, rpm]) == [.engineRPM])
        #expect(await !worker.isPollable(load))
    }

    @Test func policyBlockedPIDIsReportedNotPolled() async throws {
        let engine = TelemetryEngine(pollingPreset: .turboDashboard)
        engine.start(transport: SimulatedELM327Transport())
        try await waitUntil(seconds: 15) { engine.state == .streaming }
        // The simulated ECU supports PID 04; Redline must still not request it,
        // and the channel says why.
        if case .unavailable(let why)? = engine.store.channel(.engineLoad)?.support {
            #expect(why.contains("read-only policy"))
        } else {
            Issue.record("engine load should be unavailable (read-only policy)")
        }
        await engine.stop()
    }
}

@Suite("Adapters: adapter protocol setting")
struct AdapterProtocolSettingTests {
    /// If the adapter's stored protocol can't be read, Redline doesn't
    /// overwrite it (no ATSP0) — it can't know whether a write is needed.
    @Test func unreadableProtocolSettingIsLeftAlone() async throws {
        let t = ScriptedTransport { cmd in
            switch cmd {
            case "ATZ": return .text("\r\rELM327 v1.5\r\r>", after: .milliseconds(2))
            case "ATDPN": return .text("?\r\r>", after: .milliseconds(2))
            case "ATI": return .text("ELM327 v1.5\r\r>", after: .milliseconds(2))
            case "AT@1": return .text("OBDII to RS232 Interpreter\r\r>", after: .milliseconds(2))
            case "ATRV": return .text("12.6V\r\r>", after: .milliseconds(2))
            default: return .text("OK\r\r>", after: .milliseconds(2))
            }
        }
        let session = ELM327Session(transport: t, log: CommLog())
        await session.start(consuming: try await t.open(log: session.log))
        let info = try await ELMInitializer().initializeAdapter(session)
        #expect(!t.writtenCommands.contains("ATSP0"))
        #expect(info.persistentAdapterWrites.isEmpty)
        #expect(info.storedProtocolBeforeInit == "?")
    }
}

@Suite("Adapters: MFi diagnostics in the debug report")
struct AccessoryDiagnosticsTests {
    static let declared = ["com.obdlink", "com.scantool.stnobd"]

    @Test func explainsAnEmptyListAsAProtocolStringMismatch() {
        let lines = AccessoryDiagnostics.reportLines(monitoring: true, declared: Self.declared, connected: [], events: [])
        #expect(lines.first == "Redline declares: com.obdlink, com.scantool.stnobd")
        #expect(lines.contains("Connected accessories reported by iOS: none"))
        #expect(lines.contains { $0.contains("protocol string is not one of the above") })
    }

    @Test func listsEveryAccessoryWithItsStatusAndProtocols() {
        let ok = AccessorySelectionTests.accessory(1, name: "Mock A", protocols: ["com.obdlink"])
        let other = AccessorySelectionTests.accessory(2, name: "Mock B", protocols: ["com.example.audio"])
        let pending = AccessorySelectionTests.accessory(3, name: "Mock C", protocols: [])
        let events = [AccessoryEvent(at: Date(), kind: .connected, accessory: ok),
                      AccessoryEvent(at: Date(), kind: .disconnected, accessory: nil)]
        let text = AccessoryDiagnostics.reportLines(monitoring: true, declared: Self.declared,
                                                    connected: [ok, other, pending], events: events).joined(separator: "\n")
        #expect(text.contains("- Mock A: SUPPORTED via com.obdlink"))
        #expect(text.contains("- Mock B: NOT SUPPORTED"))
        #expect(text.contains("Advertised protocols: com.example.audio"))
        #expect(text.contains("- Mock C: not ready"))
        #expect(text.contains("connected  Mock A [com.obdlink]"))
        #expect(text.contains("disconnected  (unknown accessory)"))
    }

    @MainActor
    @Test func appendixSectionsAppearBeforeTheRawLog() {
        let engine = TelemetryEngine()
        let report = engine.debugReport(appVersion: "t", appendix: [
            DebugReportSection(title: "MFi accessories (External Accessory)", lines: ["Redline declares: com.obdlink"]),
            DebugReportSection(title: "Bluetooth LE", lines: []),
        ])
        let mfi = report.range(of: "== MFi accessories (External Accessory) ==")
        let raw = report.range(of: "== Raw log")
        #expect(mfi != nil && raw != nil && mfi!.lowerBound < raw!.lowerBound)
        #expect(report.contains("== Bluetooth LE ==\n(none)"))
    }
}
