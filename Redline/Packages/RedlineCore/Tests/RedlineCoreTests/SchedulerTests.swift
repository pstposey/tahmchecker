import Testing
@testable import RedlineCore

@Suite("Poll scheduler")
struct SchedulerTests {
    let rpm = PIDKey(mode: 1, pid: 0x0C)
    let map = PIDKey(mode: 1, pid: 0x0B)
    let timing = PIDKey(mode: 1, pid: 0x0E)
    let coolant = PIDKey(mode: 1, pid: 0x05)

    func makeScheduler() -> PollScheduler {
        var s = PollScheduler()
        s.setEntries([(rpm, .fast, nil), (map, .fast, nil), (timing, .medium, nil), (coolant, .slow, nil)])
        return s
    }

    /// Simulates a saturated adapter answering every request in `rtt`.
    func run(_ s: inout PollScheduler, seconds: Double, rtt: Duration) -> [PIDKey: Int] {
        let clock = ContinuousClock()
        var now = clock.now
        let end = now + .seconds(seconds)
        var counts: [PIDKey: Int] = [:]
        while now < end {
            switch s.next(now: now) {
            case .poll(let key):
                s.markRequested(key, at: now)
                now += rtt
                s.markResult(key, success: true, at: now)
                counts[key, default: 0] += 1
            case .idle(let until):
                now = max(until, now + .milliseconds(1))
            case .nothingToPoll:
                return counts
            }
        }
        return counts
    }

    @Test func pollsNeverPolledFirstInPriorityOrder() {
        var s = makeScheduler()
        let now = ContinuousClock().now
        var order: [PIDKey] = []
        for _ in 0..<4 {
            guard case .poll(let k) = s.next(now: now) else { Issue.record("expected poll"); return }
            order.append(k)
            s.markRequested(k, at: now)
        }
        #expect(order == [map, rpm, timing, coolant]) // fast (by PID), medium, slow
    }

    @Test func fastChannelsGetMostBandwidthAndSlowAreNotStarved() {
        var s = makeScheduler()
        // 40 ms round trip → 25 requests/s total, saturated.
        let counts = run(&s, seconds: 30, rtt: .milliseconds(40))
        let rpmRate = Double(counts[rpm] ?? 0) / 30
        let timingRate = Double(counts[timing] ?? 0) / 30
        let coolantRate = Double(counts[coolant] ?? 0) / 30
        #expect(rpmRate > timingRate)
        #expect(timingRate > coolantRate)
        #expect(coolantRate > 0.2) // slow channel still served
        #expect(rpmRate > 8)
    }

    @Test func eagerFastPollingWhenUnderloaded() {
        // Fast adapter (10 ms): fast channels exceed their 10 Hz target
        // instead of idling; slow channels stay near their target.
        var s = makeScheduler()
        let counts = run(&s, seconds: 20, rtt: .milliseconds(10))
        #expect(Double(counts[rpm] ?? 0) / 20 > 20)
        let coolantRate = Double(counts[coolant] ?? 0) / 20
        #expect(coolantRate > 0.4 && coolantRate < 0.7)
    }

    @Test func idlesWhenOnlySlowChannelsAndNothingDue() {
        var s = PollScheduler()
        s.setEntries([(coolant, .slow, nil)])
        let t0 = ContinuousClock().now
        #expect(s.next(now: t0) == .poll(coolant))
        s.markRequested(coolant, at: t0)
        s.markResult(coolant, success: true, at: t0)
        #expect(s.next(now: t0 + .milliseconds(500)) == .idle(until: t0 + .seconds(2)))
    }

    @Test func failingPIDIsSuspendedWithBackoffAndRecovers() {
        var s = PollScheduler()
        s.setEntries([(rpm, .fast, nil), (map, .fast, nil)])
        var now = ContinuousClock().now
        for _ in 0..<3 {
            s.markRequested(map, at: now)
            #expect(s.entries[map]?.isSuspended == false)
            s.markResult(map, success: false, at: now)
            now += .milliseconds(10)
        }
        #expect(s.entries[map]?.isSuspended == true)
        // While suspended only RPM is polled.
        for _ in 0..<10 {
            guard case .poll(let k) = s.next(now: now) else { Issue.record("expected poll"); return }
            #expect(k == rpm)
            s.markRequested(k, at: now)
            now += .milliseconds(20)
        }
        // After the backoff, MAP is retried and success clears the suspension.
        now += .seconds(2)
        _ = s.next(now: now)
        #expect(s.entries[map]?.isSuspended == false)
        s.markResult(map, success: true, at: now)
        #expect(s.entries[map]?.consecutiveFailures == 0)
    }

    @Test func emptySetHasNothingToPoll() {
        var s = PollScheduler()
        #expect(s.next(now: ContinuousClock().now) == .nothingToPoll)
    }

    @Test func setEntriesPreservesState() {
        var s = makeScheduler()
        let t = ContinuousClock().now
        s.markRequested(rpm, at: t)
        s.setEntries([(rpm, .fast, nil)])
        #expect(s.entries[rpm]?.lastRequestedAt == t)
        #expect(s.entries.count == 1)
    }
}
