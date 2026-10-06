import RedlineCore
import SwiftUI
import UIKit

/// Developer console: link, adapter, protocol, raw traffic, latency and
/// throughput. Kept out of the driving UI.
struct DebugView: View {
    @Environment(AppModel.self) private var model
    @State private var consoleInput = ""
    @State private var consoleOutput = ""
    @State private var consoleBusy = false
    @State private var report: String?
    @State private var copied = false

    var body: some View {
        @Bindable var model = model
        let engine = model.engine
        NavigationStack {
            List {
                Section {
                    StatusBanner(engine: engine, isSimulation: model.isSimulationActive)
                    // Generated on demand: the report includes the raw log and
                    // must not be rebuilt on every telemetry update.
                    Button("Prepare debug report") {
                        report = engine.debugReport(appVersion: model.appVersion)
                        copied = false
                    }
                    if let report {
                        HStack {
                            ShareLink(item: report) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            Spacer()
                            Button(copied ? "Copied" : "Copy") {
                                UIPasteboard.general.string = report
                                copied = true
                            }
                        }
                    }
                }

                Section("Performance (live)") {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        PerformanceRows(snapshot: engine.performanceSnapshot())
                    }
                }

                Section("Channels — target vs measured") {
                    ForEach(engine.polledChannels.sorted(), id: \.self) { id in
                        if let channel = engine.store.channel(id) {
                            ChannelRateRow(channel: channel)
                        }
                    }
                    if let boost = engine.store.channel(.boost) {
                        BoostDerivationRow(channel: boost)
                    }
                }

                Section {
                    Picker("Polled set", selection: $model.settings.pollingPreset) {
                        ForEach(PollingPreset.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Physical addressing (ATSH 7E0)", isOn: $model.settings.elmOptions.physicalAddressing)
                    Toggle("Response-count hint (\"010C1\")", isOn: $model.settings.elmOptions.responseCountHint)
                    Button("Reconnect to apply") { model.reconnect() }
                } header: {
                    Text("Polling experiments")
                } footer: {
                    Text("Both options are EXPERIMENTAL and off by default. Compare round-trip times with each on/off and share the report.")
                }

                Section("Link") {
                    if let id = engine.transportIdentity {
                        LabeledContent("Source", value: id.kind == .simulated ? "SIMULATION" : "Bluetooth LE")
                        LabeledContent("Name", value: id.name)
                    }
                    ForEach(engine.linkDetails?.items ?? []) { item in
                        LabeledContent(item.key) {
                            Text(item.value).font(.caption.monospaced()).multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section("Adapter / vehicle") {
                    if let a = engine.adapterInfo {
                        LabeledContent("ATZ banner", value: a.resetBanner ?? "-")
                        LabeledContent("Reported version", value: a.reportedVersion ?? "-")
                        LabeledContent("ATI", value: a.identification ?? "-")
                        LabeledContent("AT@1", value: a.deviceDescription ?? "-")
                        LabeledContent("Adapter voltage", value: a.adapterVoltage ?? "-")
                        LabeledContent("Protocol", value: a.obdProtocol?.displayName ?? "-")
                        LabeledContent("ECUs", value: a.responders.map(\.description).joined(separator: ", "))
                        LabeledContent("Addressing", value: a.physicalRequestHeader.map { "Physical \($0)" } ?? "Functional 7DF")
                    } else {
                        Text("Not initialized").foregroundStyle(.secondary)
                    }
                    if let support = engine.support {
                        ForEach(support.respondingECUs, id: \.self) { ecu in
                            LabeledContent("PIDs @ \(ecu.description)") {
                                Text((support.byECU[ecu] ?? []).sorted().map(Hex.byteString).joined(separator: " "))
                                    .font(.caption2.monospaced())
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        TextField("e.g. 010C, 0105, ATRV", text: $consoleInput)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .onSubmit(sendConsole)
                        Button("Send", action: sendConsole)
                            .disabled(consoleInput.isEmpty || consoleBusy)
                    }
                    if !consoleOutput.isEmpty {
                        Text(consoleOutput)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("ELM console")
                } footer: {
                    Text("Read-only: service 01/02/03/06/07/09/0A/22 requests and informational AT commands. Clearing codes and all write services are blocked.")
                }

                Section {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        RawLogView(entries: engine.log.entries(last: 200))
                    }
                    Button("Clear log", role: .destructive) { engine.log.clear() }
                } header: {
                    Text("Raw communication")
                }
            }
            .navigationTitle("Debug")
        }
    }

    private func sendConsole() {
        let command = consoleInput
        guard !command.isEmpty else { return }
        consoleBusy = true
        Task {
            consoleOutput = "> \(command)\n" + (await model.engine.sendConsoleCommand(command))
            consoleBusy = false
        }
    }
}

private struct PerformanceRows: View {
    let snapshot: PerformanceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Requests", String(format: "%.1f ok/s · %.1f fail/s", snapshot.successPerSecond, snapshot.failurePerSecond))
            row("Round trip", "last \(ms(snapshot.lastRoundTripMs)) · p50 \(ms(snapshot.medianRoundTripMs)) · p95 \(ms(snapshot.p95RoundTripMs))")
            row("First byte p50", ms(snapshot.medianFirstByteMs))
            row("Decode p50", ms(snapshot.medianDecodeMs))
            row("Publish p50", ms(snapshot.medianPublishMs))
            row("Totals", "\(snapshot.totalRequests) req · \(snapshot.totalFailures) fail · \(snapshot.totalTimeouts) timeouts")
            row("Queue depth", "\(snapshot.queueDepth)")
            ForEach(snapshot.perCommand) { c in
                row(c.command, String(format: "%.1f Hz · ", c.rateHz) + "p50 \(ms(c.medianRoundTripMs)) · fail \(c.failuresInWindow)")
            }
        }
        .font(.caption.monospacedDigit())
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    private func ms(_ v: Double?) -> String {
        v.map { String(format: "%.1f ms", $0) } ?? "-"
    }
}

private struct ChannelRateRow: View {
    let channel: ChannelState

    var body: some View {
        let target = 1 / channel.descriptor.pollingClass.targetInterval.seconds
        HStack {
            Text(channel.descriptor.shortName)
            Spacer()
            Text(String(format: "target %.1f Hz · ", target)
                 + (channel.observedRateHz.map { String(format: "measured %.1f Hz", $0) } ?? "measured -"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(channel.isStale ? Color.orange : Color.secondary)
            if channel.invalidCount > 0 {
                Text("\(channel.invalidCount) invalid")
                    .font(.caption)
                    .foregroundStyle(Theme.redline)
            }
        }
    }
}

/// Separate view so per-sample updates re-render only this row.
private struct BoostDerivationRow: View {
    let channel: ChannelState

    var body: some View {
        if let derivation = channel.latest?.derivation {
            LabeledContent("BOOST (calc)", value: derivation)
                .font(.caption.monospacedDigit())
        }
    }
}

private struct RawLogView: View {
    let entries: [CommLogEntry]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(entries.reversed()) { e in
                HStack(alignment: .top, spacing: 6) {
                    Text(e.kind.rawValue)
                        .foregroundStyle(color(e.kind))
                    Text(e.visibleText)
                        .foregroundStyle(.primary)
                    if let latency = e.latency {
                        Spacer(minLength: 4)
                        Text(String(format: "%.0fms", latency.milliseconds))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
            }
        }
        .textSelection(.enabled)
    }

    private func color(_ kind: CommLogEntry.Kind) -> Color {
        switch kind {
        case .tx: return .blue
        case .rx: return .green
        case .info: return .secondary
        case .warning: return .orange
        case .error: return Theme.redline
        }
    }
}
