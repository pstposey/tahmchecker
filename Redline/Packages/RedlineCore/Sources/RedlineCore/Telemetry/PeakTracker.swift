/// Tracks a channel's peak according to its `PeakPolicy`.
public struct PeakTracker: Sendable, Equatable {
    public let policy: PeakPolicy
    public private(set) var peak: Double?

    public init(policy: PeakPolicy) {
        self.policy = policy
    }

    public mutating func observe(_ value: Double) {
        guard value.isFinite else { return }
        switch policy {
        case .none:
            return
        case .maximum:
            if peak.map({ value > $0 }) ?? true { peak = value }
        case .maximumPositive:
            guard value > 0 else { return }
            if peak.map({ value > $0 }) ?? true { peak = value }
        case .minimum:
            if peak.map({ value < $0 }) ?? true { peak = value }
        }
    }

    public mutating func reset() {
        peak = nil
    }
}

/// Session minimum/maximum of valid samples (independent of peak policy).
public struct RangeTracker: Sendable, Equatable {
    public private(set) var minimum: Double?
    public private(set) var maximum: Double?

    public init() {}

    public mutating func observe(_ value: Double) {
        guard value.isFinite else { return }
        if minimum.map({ value < $0 }) ?? true { minimum = value }
        if maximum.map({ value > $0 }) ?? true { maximum = value }
    }

    public mutating func reset() {
        minimum = nil
        maximum = nil
    }
}
