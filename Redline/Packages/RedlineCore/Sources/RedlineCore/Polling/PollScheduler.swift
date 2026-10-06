/// Decides which PID to request next. Pure value type — no clocks, no I/O —
/// so its behaviour is unit-testable.
///
/// Design: pull-based. The polling loop asks for *one* next request each
/// time the adapter becomes free; there is no request queue, so a queue can
/// never grow without bound and work never goes obsolete while waiting.
///
/// Selection:
/// 1. Never-polled entries first (fast class first).
/// 2. Otherwise the entry most overdue relative to its own target interval
///    (`elapsed / interval`). Under saturation this shares bandwidth in
///    proportion to 1/interval — fast channels get the most, slow channels
///    degrade proportionally but are never starved.
/// 3. If nothing is due, eager (fast-class) entries are polled anyway: fast
///    signals run as fast as the adapter sustains. With no eager entries the
///    loop idles until the next due time.
///
/// Failure backoff: after `suspendAfterFailures` consecutive failures
/// (e.g. NO DATA) an entry is suspended with exponential backoff, so a PID
/// the ECU stopped answering cannot eat bandwidth.
public struct PollScheduler: Sendable {
    public struct Entry: Sendable, Equatable {
        public let key: PIDKey
        public var pollingClass: PollingClass
        public var interval: Duration
        public var eager: Bool
        public var lastRequestedAt: MonotonicInstant?
        public var consecutiveFailures = 0
        public var suspendedUntil: MonotonicInstant?

        public var isSuspended: Bool { suspendedUntil != nil }
    }

    public enum Decision: Sendable, Equatable {
        case poll(PIDKey)
        case idle(until: MonotonicInstant)
        case nothingToPoll
    }

    public private(set) var entries: [PIDKey: Entry] = [:]
    public var suspendAfterFailures = 3
    public var maxSuspension: Duration = .seconds(30)

    public init() {}

    /// Replaces the polled set, keeping timing/failure state for keys that
    /// remain. `intervalOverride` lets a caller (e.g. dashboard visibility)
    /// tighten or relax a channel's interval without changing its class.
    public mutating func setEntries(_ items: [(key: PIDKey, pollingClass: PollingClass, intervalOverride: Duration?)]) {
        var next: [PIDKey: Entry] = [:]
        for item in items {
            let interval = item.intervalOverride ?? item.pollingClass.targetInterval
            if var existing = entries[item.key] {
                existing.pollingClass = item.pollingClass
                existing.interval = interval
                existing.eager = item.pollingClass == .fast
                next[item.key] = existing
            } else {
                next[item.key] = Entry(
                    key: item.key, pollingClass: item.pollingClass, interval: interval,
                    eager: item.pollingClass == .fast
                )
            }
        }
        entries = next
    }

    public mutating func next(now: MonotonicInstant) -> Decision {
        // Lift expired suspensions.
        for (key, e) in entries where e.suspendedUntil.map({ now >= $0 }) ?? false {
            entries[key]?.suspendedUntil = nil
        }
        let active = entries.values.filter { !$0.isSuspended }
        guard !active.isEmpty else {
            if let soonest = entries.values.compactMap(\.suspendedUntil).min() {
                return .idle(until: soonest)
            }
            return .nothingToPoll
        }

        if let fresh = active.filter({ $0.lastRequestedAt == nil }).min(by: Self.priorityOrder) {
            return .poll(fresh.key)
        }

        func ratio(_ e: Entry) -> Double {
            (now - e.lastRequestedAt!).seconds / max(e.interval.seconds, 0.001)
        }
        func moreOverdue(_ a: Entry, _ b: Entry) -> Bool {
            let ra = ratio(a), rb = ratio(b)
            if ra != rb { return ra > rb }
            return Self.priorityOrder(a, b)
        }

        let best = active.min(by: moreOverdue)!
        if ratio(best) >= 1 { return .poll(best.key) }

        if let eager = active.filter(\.eager).min(by: moreOverdue) {
            return .poll(eager.key)
        }
        let due = active.map { $0.lastRequestedAt! + $0.interval }.min()!
        return .idle(until: due)
    }

    public mutating func markRequested(_ key: PIDKey, at time: MonotonicInstant) {
        entries[key]?.lastRequestedAt = time
    }

    /// Records the outcome. Returns true if this call suspended the entry.
    @discardableResult
    public mutating func markResult(_ key: PIDKey, success: Bool, at time: MonotonicInstant) -> Bool {
        guard var e = entries[key] else { return false }
        defer { entries[key] = e }
        if success {
            e.consecutiveFailures = 0
            e.suspendedUntil = nil
            return false
        }
        e.consecutiveFailures += 1
        guard e.consecutiveFailures >= suspendAfterFailures else { return false }
        let exponent = min(e.consecutiveFailures - suspendAfterFailures, 5)
        let backoff = min(Duration.seconds(1 << exponent), maxSuspension)
        e.suspendedUntil = time + backoff
        return true
    }

    static func priorityOrder(_ a: Entry, _ b: Entry) -> Bool {
        if a.pollingClass != b.pollingClass { return a.pollingClass < b.pollingClass }
        return a.key < b.key
    }
}
