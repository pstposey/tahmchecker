import RedlineCore
import SwiftUI

/// Choose the data source: an OBD adapter (OBDLink MX+ over MFi, or a BLE
/// adapter such as the Vgate iCar Pro 2S) or the simulator.
struct ConnectView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    StatusBanner(engine: model.engine, isSimulation: model.isSimulationActive)
                    if let id = model.engine.transportIdentity, model.engine.state != .idle {
                        LabeledContent("Link", value: id.kind.isSimulation ? "Simulator" : "\(id.name) · \(Self.kindLabel(id.kind))")
                            .font(.caption)
                    }
                    if model.engine.state != .idle {
                        Button("Disconnect", role: .destructive) { model.disconnect() }
                    }
                }

                if let remembered = model.settings.rememberedAdapter {
                    Section("Adapter") {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(remembered.displayName)
                                Text(rememberedCaption(remembered))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Connect") { model.connectRememberedAdapter() }
                        }
                        Toggle("Connect automatically at launch", isOn: $model.settings.autoConnect)
                        Button("Forget adapter", role: .destructive) { model.forgetAdapter() }
                    }
                }

                accessorySection
                bluetoothLESection

                Section("Simulation") {
                    Picker("Scenario", selection: $model.settings.simulationScenario) {
                        ForEach(SimulationScenario.allCases) { Text($0.title).tag($0) }
                    }
                    Button(model.isSimulationActive ? "Restart simulation" : "Start simulation") {
                        model.startSimulation()
                    }
                    Text("Simulated data runs through the same ELM327 parser and scheduler as a real adapter, and is always labelled SIMULATION.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Units") {
                    Picker("Pressure", selection: $model.settings.units.pressure) {
                        ForEach(PressureUnit.allCases) { Text($0.symbol).tag($0) }
                    }
                    Picker("Temperature", selection: $model.settings.units.temperature) {
                        ForEach(TemperatureUnit.allCases) { Text($0.symbol).tag($0) }
                    }
                    Picker("Speed", selection: $model.settings.units.speed) {
                        ForEach(SpeedUnit.allCases) { Text($0.symbol).tag($0) }
                    }
                    Toggle("Keep screen awake while connected", isOn: $model.settings.keepScreenAwake)
                }
            }
            .navigationTitle("Connect")
            .onAppear {
                model.prepareAccessories()
                model.refreshAccessories()
                // Only touch Bluetooth LE (and its permission prompt) for a
                // BLE adapter; the MX+ path doesn't need it.
                if model.settings.dataSource == .vehicle, model.settings.rememberedAdapter?.transport == .bluetoothLE {
                    model.prepareBluetooth()
                }
            }
            .onDisappear { model.stopScan() }
        }
    }

    // MARK: OBDLink MX+ (MFi, External Accessory)

    private var accessorySection: some View {
        Section {
            if model.accessories.connected.isEmpty {
                Text("No MFi accessory is connected to this iPhone.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.accessories.connected) { accessory in
                let supported = model.accessories.supportedProtocol(of: accessory) != nil
                Button {
                    model.connect(toAccessory: accessory)
                } label: {
                    accessoryRow(accessory, supported: supported)
                }
                .disabled(!supported)
            }
            Button("Refresh") { model.refreshAccessories() }
        } header: {
            Text("OBDLink MX+ (Made for iPhone)")
        } footer: {
            Text("Pair once in iOS Settings › Bluetooth: plug the MX+ into the OBD port, press its Connect button (blue LED blinks fast), then tap “OBDLink MX+” within 2 minutes. iOS connects it automatically afterwards; it can take up to a minute to appear after plugging in. Only one app can use the adapter at a time, so close the OBDLink app and other OBD apps first.\n\nConnected in Settings but not listed here? Redline may not know this adapter's protocol string yet: send the debug report (Debug tab).")
        }
    }

    private func accessoryRow(_ a: AccessoryDescriptor, supported: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(a.displayName).foregroundStyle(.primary)
            Text([a.manufacturer, a.modelNumber, a.firmwareRevision.isEmpty ? "" : "fw \(a.firmwareRevision)"]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(accessoryStatus(a, supported: supported))
                .font(.caption2)
                .foregroundStyle(supported ? Theme.ok : Theme.label)
                .lineLimit(2)
        }
    }

    private func accessoryStatus(_ a: AccessoryDescriptor, supported: Bool) -> String {
        if supported { return "Ready — tap to connect" }
        if a.protocolStrings.isEmpty { return "Waiting for iOS to finish authenticating the accessory…" }
        return "Not supported: offers \(a.protocolStrings.joined(separator: ", "))"
    }

    // MARK: Bluetooth LE (Vgate iCar Pro 2S)

    private var bluetoothLESection: some View {
        @Bindable var model = model
        return Group {
            Section {
                Text(model.bluetooth.availability.title)
                    .foregroundStyle(.secondary)
                if model.bluetooth.isScanning {
                    Button("Stop scanning") { model.stopScan() }
                } else {
                    Button("Scan for Bluetooth LE adapters") { model.startScan() }
                }
                Toggle("Show all Bluetooth LE devices", isOn: $model.settings.showAllBluetoothDevices)
            } header: {
                Text("Bluetooth LE adapters (Vgate iCar Pro 2S)")
            } footer: {
                Text("BLE adapters are found by scanning here, not in iOS Settings. The OBDLink MX+ does not use Bluetooth LE and won't appear in this list.")
            }

            if !visibleAdapters.isEmpty {
                Section {
                    ForEach(visibleAdapters) { adapter in
                        Button {
                            model.connect(to: adapter)
                        } label: {
                            adapterRow(adapter)
                        }
                    }
                } header: {
                    Text("Nearby")
                } footer: {
                    Text("Names are only a hint. Redline verifies the adapter by talking to it (ELM327 probe) when you connect.")
                }
            }
        }
    }

    private var visibleAdapters: [DiscoveredAdapter] {
        model.bluetooth.discovered
            .filter { model.settings.showAllBluetoothDevices || $0.name != nil }
            .sorted { a, b in
                if a.looksLikeOBDAdapter != b.looksLikeOBDAdapter { return a.looksLikeOBDAdapter }
                return a.rssi > b.rssi
            }
    }

    private func adapterRow(_ adapter: DiscoveredAdapter) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(adapter.displayName)
                    .foregroundStyle(.primary)
                Text(adapter.advertisedServices.isEmpty
                     ? adapter.id.uuidString
                     : "Advertises: " + adapter.advertisedServices.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if adapter.looksLikeOBDAdapter {
                Text("OBD?").font(.caption).foregroundStyle(.secondary)
            }
            Text("\(adapter.rssi) dBm")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private func rememberedCaption(_ r: RememberedAdapter) -> String {
        switch r {
        case .bluetoothLE(_, _, let link):
            return "Bluetooth LE adapter" + (link == nil ? "" : " · link verified")
        case .externalAccessory(let a):
            return "MFi accessory" + (a.modelNumber.isEmpty ? "" : " · \(a.modelNumber)")
        }
    }

    static func kindLabel(_ kind: TransportKind) -> String {
        switch kind {
        case .bluetoothLE: return "Bluetooth LE"
        case .externalAccessory: return "MFi accessory"
        case .simulated: return "Simulator"
        }
    }
}
