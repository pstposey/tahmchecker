import Foundation

/// One measured request.
public struct ExchangeRecord: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case success
        /// The vehicle/adapter answered with a status such as NO DATA.
        case noData(String)
        case malformed(String)
        case timeout
    }

    public let command: String
    public let sentAt: MonotonicInstant
    public let firstByteAt: MonotonicInstant?
    /// Prompt received (or the moment the timeout fired).
    public let completedAt: MonotonicInstant
    public let decodedAt: MonotonicInstant?
    public let outcome: Outcome

    public init(command: String, sentAt: MonotonicInstant, firstByteAt: MonotonicInstant?,
                completedAt: MonotonicInstant, decodedAt: MonotonicInstant?, outcome: Outcome) {
        self.command = command
        self.sentAt = sentAt
        self.firstByteAt = firstByteAt
        self.completedAt = completedAt
        self.decodedAt = decodedAt
        self.outcome = outcome
    }

    public var roundTrip: Duration { completedAt - sentAt }
    public var isSuccess: Bool { outcome == .success }
}

public struct CommandStats: Sendable, Equatable, Identifiable {
    public var id: String { command }
    public let command: String
    public let successesInWindow: Int
    public let failuresInWindow: Int
    /// Successful responses per second over the window.
    public let rateHz: Double
    public let medianRoundTripMs: Double?
}

/// Aggregated, display-ready metrics.
public struct PerformanceSnapshot: Sendable, Equatable {
    public var windowSeconds: Double = 0
    public var successPerSecond: Double = 0
    public var failurePerSecond: Double = 0
    public var totalRequests = 0
    public var totalFailures = 0
    public var totalTimeouts = 0
    public var lastRoundTripMs: Double?
    public var medianRoundTripMs: Double?
    public var p95RoundTripMs: Double?
    public var maxRoundTripMs: Double?
    /// Request sent → first response byte received.
    public var medianFirstByteMs: Double?
    /// Prompt received → value decoded.
    public var medianDecodeMs: Double?
    /// Response received → published to the UI store.
    public var medianPublishMs: Double?
    public var queueDepth = 0
    public var perCommand: [CommandStats] = []

    public init() {}
}

/// Thread-safe collector of request timings. Recording is O(1) amortized;
/// aggregation happens only when a snapshot is requested (debug screen,
/// ~1 Hz), so measurement does not slow the hot path.
public final class PerformanceMonitor: Sendable {
    private struct State {
        var records: [ExchangeRecord] = []
        var publishLatencies: [Double] = []
        var totalRequests = 0
        var totalFailures = 0
        var totalTimeouts = 0
        var queueDepth = 0
    }

    public let window: Duration
    private let maxRecords = 4_000
    private let state = Locked(State())

    public init(window: Duration = .seconds(5)) {
        self.window = window
    }

    public func record(_ r: ExchangeRecord) {
        state.withLock { s in
            s.records.append(r)
            if s.records.count > maxRecords { s.records.removeFirst(s.records.count - maxRecords) }
            s.totalRequests += 1
            if !r.isSuccess { s.totalFailures += 1 }
            if r.outcome == .timeout { s.totalTimeouts += 1 }
        }
    }

    public func recordPublish(latency: Duration) {
        state.withLock { s in
            s.publishLatencies.append(latency.milliseconds)
            if s.publishLatencies.count > 500 { s.publishLatencies.removeFirst(s.publishLatencies.count - 500) }
        }
    }

    public func setQueueDepth(_ depth: Int) {
        state.withLock { $0.queueDepth = depth }
    }

    public func reset() {
        state.withLock { $0 = State() }
    }

    public func snapshot(now: MonotonicInstant) -> PerformanceSnapshot {
        let s = state.withLock { $0 }
        var snap = PerformanceSnapshot()
        let cutoff = now - window
        let recent = s.records.filter { $0.completedAt >= cutoff }
        let windowSeconds = window.seconds
        snap.windowSeconds = windowSeconds
        snap.totalRequests = s.totalRequests
        snap.totalFailures = s.totalFailures
        snap.totalTimeouts = s.totalTimeouts
        snap.queueDepth = s.queueDepth

        let ok = recent.filter(\.isSuccess)
        snap.successPerSecond = Double(ok.count) / windowSeconds
        snap.failurePerSecond = Double(recent.count - ok.count) / windowSeconds

        let rtts = ok.map { $0.roundTrip.milliseconds }.sorted()
        snap.lastRoundTripMs = s.records.last(where: \.isSuccess)?.roundTrip.milliseconds
        snap.medianRoundTripMs = Self.percentile(rtts, 0.5)
        snap.p95RoundTripMs = Self.percentile(rtts, 0.95)
        snap.maxRoundTripMs = rtts.last
        snap.medianFirstByteMs = Self.percentile(
            ok.compactMap { r in r.firstByteAt.map { ($0 - r.sentAt).milliseconds } }.sorted(), 0.5)
        snap.medianDecodeMs = Self.percentile(
            ok.compactMap { r in r.decodedAt.map { ($0 - r.completedAt).milliseconds } }.sorted(), 0.5)
        snap.medianPublishMs = Self.percentile(s.publishLatencies.suffix(100).sorted(), 0.5)

        let grouped = Dictionary(grouping: recent, by: \.command)
        snap.perCommand = grouped.map { command, rs in
            let successes = rs.filter(\.isSuccess)
            return CommandStats(
                command: command,
                successesInWindow: successes.count,
                failuresInWindow: rs.count - successes.count,
                rateHz: Double(successes.count) / windowSeconds,
                medianRoundTripMs: Self.percentile(successes.map { $0.roundTrip.milliseconds }.sorted(), 0.5)
            )
        }.sorted { $0.command < $1.command }
        return snap
    }

    /// Nearest-rank percentile of an ascending array.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
