import RedlineCore
import SwiftUI

/// Milestone 1/2 live screen: RPM hero plus boost and its inputs.
/// Deliberately simple — the modular dashboard is Phase 9/10.
struct LiveView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.engine.store
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            VStack(spacing: Theme.spacing) {
                StatusBanner(engine: model.engine, isSimulation: model.isSimulationActive)
                if model.engine.state == .idle {
                    notConnected
                } else if landscape {
                    HStack(spacing: Theme.spacing) {
                        hero(store, size: geo.size)
                            .frame(width: geo.size.width * 0.42)
                        secondaryGrid(store, columns: 2)
                    }
                } else {
                    hero(store, size: geo.size)
                        .frame(height: geo.size.height * 0.36)
                    secondaryGrid(store, columns: 2)
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.background)
    }

    private func hero(_ store: TelemetryStore, size: CGSize) -> some View {
        Group {
            if let rpm = store.channel(.engineRPM) {
                GaugeTile(channel: rpm, presenter: model.presenter,
                          valueSize: min(size.width, size.height) * 0.26, showPeak: true)
            }
        }
    }

    private func secondaryGrid(_ store: TelemetryStore, columns: Int) -> some View {
        let ids: [ChannelID] = [.boost, .manifoldPressure, .barometricPressure, .coolantTemp]
        let grid = Array(repeating: GridItem(.flexible(), spacing: Theme.spacing), count: columns)
        return LazyVGrid(columns: grid, spacing: Theme.spacing) {
            ForEach(ids, id: \.self) { id in
                if let channel = store.channel(id) {
                    GaugeTile(channel: channel, presenter: model.presenter, valueSize: 40,
                              showPeak: id == .boost)
                        .frame(minHeight: 120)
                }
            }
        }
    }

    private var notConnected: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("REDLINE")
                .font(.system(size: 34, weight: .heavy, design: .default))
                .tracking(6)
                .foregroundStyle(Theme.value)
            Text("Not connected")
                .foregroundStyle(Theme.label)
            if model.settings.rememberedAdapterID != nil {
                Button("Connect to \(model.settings.rememberedAdapterName ?? "adapter")") {
                    model.connectRememberedAdapter()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.redline)
            }
            Text("Use the Connect tab to pair an adapter or start the simulator.")
                .font(.footnote)
                .foregroundStyle(Theme.label)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
