import RedlineCore
import SwiftUI

/// Choose the data source: a real OBD adapter (BLE) or the simulator.
struct ConnectView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    StatusBanner(engine: model.engine, isSimulation: model.isSimulationActive)
                    if model.engine.state != .idle {
                        Button("Disconnect", role: .destructive) { model.disconnect() }
                    }
                }

                Section("Vehicle") {
                    Text(model.bluetooth.availability.title)
                        .foregroundStyle(.secondary)
                    if let name = model.settings.rememberedAdapterName {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(name)
                                Text(model.settings.verifiedLink == nil
                                     ? "Remembered adapter"
                                     : "Remembered adapter · link verified")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Connect") { model.connectRememberedAdapter() }
                        }
                        Button("Forget adapter", role: .destructive) { model.forgetAdapter() }
                    }
                    Toggle("Connect automatically at launch", isOn: $model.settings.autoConnect)
                    if model.bluetooth.isScanning {
                        Button("Stop scanning") { model.stopScan() }
                    } else {
                        Button("Scan for adapters") { model.startScan() }
                    }
                    Toggle("Show all Bluetooth devices", isOn: $model.settings.showAllBluetoothDevices)
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
                // Only touch Bluetooth (and its permission prompt) for real-vehicle use.
                if model.settings.dataSource == .vehicle { model.prepareBluetooth() }
            }
            .onDisappear { model.stopScan() }
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
}
