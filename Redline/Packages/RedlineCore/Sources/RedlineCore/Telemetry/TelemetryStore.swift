import Foundation
import Observation

/// Central, UI-independent telemetry state.
///
/// Every consumer (iPhone dashboard, future CarPlay/external display, logger)
/// reads from here; none of them issues OBD commands. The store is identical
/// whether data comes from a real adapter or the simulator — only
/// `sourceKind` differs, and the UI must surface it.
@MainActor
@Observable
public final class TelemetryStore {
    /// Fixed after init; per-channel changes are observed on `ChannelState`.
    @ObservationIgnored public let channels: [ChannelID: ChannelState]
    @ObservationIgnored public let orderedChannelIDs: [ChannelID]

    /// Where current data comes from. `.simulated` must be visibly labelled.
    public internal(set) var sourceKind: TransportKind?

    /// Called with (publish time − receive time) for each published sample.
    @ObservationIgnored public var onPublishLatency: (@MainActor (Duration) -> Void)?

    @ObservationIgnored private let clock = ContinuousClock()

    public init(descriptors: [ChannelDescriptor] = StandardPIDs.allChannels) {
        var map: [ChannelID: ChannelState] = [:]
        for d in descriptors { map[d.id] = ChannelState(descriptor: d) }
        self.channels = map
        self.orderedChannelIDs = descriptors.map(\.id)
    }

    public func channel(_ id: ChannelID) -> ChannelState? { channels[id] }

    // MARK: Ingest

    public func apply(_ updates: [TelemetryUpdate]) {
        let now = clock.now
        for update in updates {
            switch update {
            case .sample(let s):
                ingest(s, now: now)
            case .support(let id, let state):
                channels[id]?.setSupport(state)
                if id == .manifoldPressure || id == .barometricPressure {
                    refreshBoostSupport()
                }
            }
        }
    }

    private func ingest(_ sample: TelemetrySample, now: MonotonicInstant) {
        guard let state = channels[sample.channel] else { return }
        state.record(sample, publishedAt: now)
        if sample.isValid {
            onPublishLatency?(now - sample.timing.receivedAt)
        }
        if sample.channel == .manifoldPressure, sample.isValid {
            deriveBoost(fromMAP: sample, now: now)
        }
    }

    /// Boost is produced once per valid MAP sample, using the latest valid
    /// BARO. It inherits the MAP sample's timing (it is that measurement,
    /// re-expressed as gauge pressure). See `BoostCalculator`.
    private func deriveBoost(fromMAP map: TelemetrySample, now: MonotonicInstant) {
        guard let boost = channels[.boost] else { return }
        guard let baro = channels[.barometricPressure]?.latest else {
            if case .unsupported = channels[.barometricPressure]?.support {
                boost.setSupport(.unavailable("Requires BARO (PID 33), which this vehicle does not report"))
            }
            return
        }
        let value = BoostCalculator.gaugePressure(manifoldAbsolute: map.value, barometric: baro.value)
        let baroAge = (map.timing.receivedAt - baro.timing.receivedAt).seconds
        let sample = TelemetrySample(
            channel: .boost,
            value: value,
            source: .calculated,
            raw: [],
            ecu: map.ecu,
            timing: map.timing,
            wallClock: map.wallClock,
            derivation: String(format: "MAP %.0f kPa − BARO %.0f kPa (BARO age %.1f s)", map.value, baro.value, max(0, baroAge))
        )
        boost.record(sample, publishedAt: now)
        if boost.support != .supported { boost.setSupport(.supported) }
    }

    private func refreshBoostSupport() {
        guard let boost = channels[.boost],
              let map = channels[.manifoldPressure]?.support,
              let baro = channels[.barometricPressure]?.support else { return }
        switch (map, baro) {
        case (.unsupported, _):
            boost.setSupport(.unavailable("Requires MAP (PID 0B), which this vehicle does not report"))
        case (_, .unsupported):
            boost.setSupport(.unavailable("Requires BARO (PID 33), which this vehicle does not report"))
        case (.supported, .supported):
            boost.setSupport(.supported)
        default:
            break
        }
    }

    // MARK: Maintenance

    public func sweepStaleness(now: MonotonicInstant? = nil) {
        let t = now ?? clock.now
        for state in channels.values { state.updateStaleness(now: t) }
    }

    public func setPolledChannels(_ ids: Set<ChannelID>) {
        for (id, state) in channels {
            state.setPolled(ids.contains(id) || (id == .boost && ids.contains(.manifoldPressure)))
        }
    }

    public func resetPeaks() {
        for state in channels.values { state.resetPeak() }
    }

    /// Clears all values and support info (new connection / new source).
    public func resetSession(sourceKind: TransportKind?) {
        for state in channels.values { state.resetSession() }
        self.sourceKind = sourceKind
    }
}
