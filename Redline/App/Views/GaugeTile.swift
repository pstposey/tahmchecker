import RedlineCore
import SwiftUI

/// Digital gauge: label, large current value, unit, optional peak.
///
/// Reads one `ChannelState`, so it re-renders only when its own channel
/// changes. The number shown is always the most recent real sample — no
/// interpolation.
struct GaugeTile: View {
    let channel: ChannelState
    let presenter: MeasurementPresenter
    var valueSize: CGFloat = 54
    var showPeak = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(channel.descriptor.shortName)
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.label)
                Spacer(minLength: 4)
                badge
            }
            Spacer(minLength: 0)
            valueRow
            if showPeak, channel.descriptor.peakPolicy != .none {
                peakRow
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.tile, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.tileBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var valueRow: some View {
        switch channel.displayStatus {
        case .unsupported:
            Text("Unsupported")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.staleValue)
        case .unavailable(let why):
            VStack(alignment: .leading, spacing: 2) {
                Text("--").font(Theme.numeric(valueSize)).foregroundStyle(Theme.staleValue)
                Text(why).font(.caption2).foregroundStyle(Theme.label).lineLimit(2)
            }
        case .waiting:
            Text("--")
                .font(Theme.numeric(valueSize))
                .foregroundStyle(Theme.staleValue)
        case .live, .stale:
            if let sample = channel.latest {
                let display = presenter.display(sample.value, for: channel.descriptor)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(display.text)
                        .font(Theme.numeric(valueSize))
                        .foregroundStyle(channel.isStale ? Theme.staleValue : Theme.value)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                    Text(display.unitSymbol)
                        .font(.system(size: max(valueSize * 0.28, 13), weight: .medium))
                        .foregroundStyle(Theme.label)
                }
            }
        }
    }

    private var peakRow: some View {
        HStack(spacing: 6) {
            Text("PEAK")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.redline.opacity(channel.peak == nil ? 0.4 : 0.9))
            if let peak = channel.peak {
                let d = presenter.display(peak, for: channel.descriptor)
                Text("\(d.text) \(d.unitSymbol)")
                    .font(Theme.numeric(15))
                    .foregroundStyle(Theme.secondaryValue)
            } else {
                Text("--").font(Theme.numeric(15)).foregroundStyle(Theme.staleValue)
            }
        }
    }

    @ViewBuilder private var badge: some View {
        if channel.isStale, channel.latest != nil {
            Text("STALE")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.caution)
        } else if channel.descriptor.source == .calculated {
            Text("CALC")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.label)
                .accessibilityLabel("Calculated value")
        }
    }
}
