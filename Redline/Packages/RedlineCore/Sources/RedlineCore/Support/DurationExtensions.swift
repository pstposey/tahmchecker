/// Monotonic timestamps are used for every latency/staleness calculation.
/// Wall-clock `Date`s are only used for human-readable logs and exports.
public typealias MonotonicInstant = ContinuousClock.Instant

extension Duration {
    /// Duration as fractional milliseconds (for metrics and display).
    public var milliseconds: Double {
        let c = components
        return Double(c.seconds) * 1_000 + Double(c.attoseconds) / 1_000_000_000_000_000
    }

    /// Duration as fractional seconds.
    public var seconds: Double { milliseconds / 1_000 }
}
