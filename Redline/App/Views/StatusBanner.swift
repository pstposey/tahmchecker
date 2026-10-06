import RedlineCore
import SwiftUI

/// Compact connection status. Simulation is always flagged unmistakably.
struct StatusBanner: View {
    let engine: TelemetryEngine
    let isSimulation: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(engine.state.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondaryValue)
            if let detail = engine.state.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isSimulation {
                Text("SIMULATION")
                    .font(.system(size: 11, weight: .heavy))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(.black)
                    .background(Theme.caution, in: Capsule())
                    .accessibilityLabel("Simulated data, not from a vehicle")
            }
        }
    }

    private var color: Color {
        switch engine.state {
        case .streaming: return Theme.ok
        case .failed, .disconnected: return Theme.redline
        case .idle: return Theme.staleValue
        default: return Theme.caution
        }
    }
}
