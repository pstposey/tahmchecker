import Observation

/// What a gauge should show for a channel right now.
public enum ChannelDisplayStatus: Sendable, Equatable {
    /// The vehicle does not report it → "Unsupported" (or hidden).
    case unsupported
    /// Supported/unknown but no valid sample yet → "--".
    case waiting
    /// Current, fresh value.
    case live
    /// Last value is older than the channel's stale threshold.
    case stale
    /// Supported but not producing data, with the reason.
    case unavailable(String)
}

/// Live state of one channel. One observable object per channel so that a
/// gauge re-renders only when *its* channel changes, not on every sample of
/// every channel.
@MainActor
@Observable
public final class ChannelState: Identifiable {
    public let descriptor: ChannelDescriptor
    public nonisolated var id: ChannelID { descriptor.id }

    public internal(set) var support: SupportState = .unknown
    /// Most recent valid sample.
    public internal(set) var latest: TelemetrySample?
    /// Most recent sample that failed decode-sanity checks.
    public internal(set) var lastInvalid: TelemetrySample?
    public internal(set) var invalidCount = 0
    public internal(set) var isStale = false
    public internal(set) var peak: Double?
    public internal(set) var sessionMinimum: Double?
    public internal(set) var sessionMaximum: Double?
    public internal(set) var sampleCount = 0
    /// Measured update rate (EWMA of inter-sample intervals).
    public internal(set) var observedRateHz: Double?
    /// Whether the engine is currently requesting this channel.
    public internal(set) var isPolled = false

    @ObservationIgnored private var peakTracker: PeakTracker
    @ObservationIgnored private var rangeTracker = RangeTracker()
    @ObservationIgnored private var intervalEWMA: Double?
    @ObservationIgnored private var lastReceivedAt: MonotonicInstant?
    /// When the latest sample was published to the UI layer.
    @ObservationIgnored public private(set) var lastPublishedAt: MonotonicInstant?

    public init(descriptor: ChannelDescriptor) {
        self.descriptor = descriptor
        self.peakTracker = PeakTracker(policy: descriptor.peakPolicy)
    }

    public var displayStatus: ChannelDisplayStatus {
        switch support {
        case .unsupported: return .unsupported
        case .unavailable(let why) where latest == nil || isStale: return .unavailable(why)
        default: break
        }
        guard latest != nil else { return .waiting }
        return isStale ? .stale : .live
    }

    func record(_ sample: TelemetrySample, publishedAt: MonotonicInstant) {
        guard sample.isValid else {
            lastInvalid = sample
            invalidCount += 1
            return
        }
        if let last = lastReceivedAt {
            let dt = (sample.timing.receivedAt - last).seconds
            if dt > 0 {
                let ewma = intervalEWMA.map { 0.8 * $0 + 0.2 * dt } ?? dt
                intervalEWMA = ewma
                observedRateHz = 1 / ewma
            }
        }
        lastReceivedAt = sample.timing.receivedAt
        lastPublishedAt = publishedAt
        latest = sample
        sampleCount += 1
        if isStale { isStale = false }

        peakTracker.observe(sample.value)
        if peak != peakTracker.peak { peak = peakTracker.peak }
        rangeTracker.observe(sample.value)
        if sessionMinimum != rangeTracker.minimum { sessionMinimum = rangeTracker.minimum }
        if sessionMaximum != rangeTracker.maximum { sessionMaximum = rangeTracker.maximum }
    }

    func updateStaleness(now: MonotonicInstant) {
        guard let latest else { return }
        let stale = now - latest.timing.receivedAt > descriptor.staleAfter
        if stale != isStale { isStale = stale }
        if stale {
            // The measured rate no longer describes reality, and the gap must
            // not be measured as a sample interval when data resumes.
            intervalEWMA = nil
            lastReceivedAt = nil
            if observedRateHz != nil { observedRateHz = nil }
        }
    }

    func setSupport(_ state: SupportState) {
        if support != state { support = state }
    }

    func setPolled(_ polled: Bool) {
        if isPolled != polled { isPolled = polled }
    }

    public func resetPeak() {
        peakTracker.reset()
        peak = nil
    }

    func resetSession() {
        resetPeak()
        rangeTracker.reset()
        sessionMinimum = nil
        sessionMaximum = nil
        latest = nil
        lastInvalid = nil
        invalidCount = 0
        sampleCount = 0
        observedRateHz = nil
        intervalEWMA = nil
        lastReceivedAt = nil
        lastPublishedAt = nil
        isStale = false
        support = .unknown
        isPolled = false
    }
}
