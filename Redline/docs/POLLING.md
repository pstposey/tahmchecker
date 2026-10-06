# Polling and latency

## Goal and rule

The reference app (WrenchTime) shows about 500 ms of *perceived* latency on this car. Redline aims to do clearly better, **measured, not claimed**. No sample is ever interpolated or synthesized to raise the apparent rate. Gauges may animate between real samples later, but the number shown is always the latest real measurement.

## Scheduler (`PollScheduler`)

Pull-based: each time the adapter is free, the worker asks for exactly one next request. There's no queue, so nothing can pile up or go stale while waiting.

Selection order:
1. Channels never polled, fast class first.
2. Otherwise the channel most overdue relative to *its own* target (`elapsed / targetInterval`).
3. If nothing is due, **fast** channels are polled anyway ("as fast as the adapter sustains"). Only if there are no fast channels does the loop sleep until the next due time.

Targets (`PollingClass`):

| Class | Target interval | Stale after | Channels |
|---|---|---|---|
| fast | 100 ms (10 Hz) | 2 s | RPM, MAP (boost), load, throttle, pedal |
| medium | 333 ms | 3 s | timing, λ, trims, rail pressure, IAT, speed |
| slow | 2 s | 10 s | coolant, BARO, fuel level, voltage, ambient |

When the adapter is saturated, the overdue-ratio rule gives each channel bandwidth in proportion to 1/interval, so everything degrades proportionally and nothing starves (tested). A channel that fails 3 times in a row (NO DATA, etc.) is suspended with exponential backoff (1 s → 30 s) and shown as unavailable with the reason.

Dashboard-driven priority (Phase 10) plugs in through `PollingWorker.setPolled(_:intervalOverrides:)`, which tightens intervals for visible tiles and drops invisible ones. Until then, **presets** choose the polled set: RPM only · RPM + Boost (default) · Turbo dashboard · Diagnostic.

## What is measured

Every request records `sentAt` (just before the write), `firstByteAt` (first notification), `completedAt` (the notification containing `>`), and `decodedAt`. The store adds the publish time. The Debug tab and debug report show:

- success and failure requests per second (5 s window), timeouts
- round trip: last / median / p95 / max
- time to first byte, decode time, publish latency
- per command: Hz, median RTT, failures
- per channel: target Hz vs measured Hz (EWMA of real sample intervals)
- queue depth (waiters on the session gate; normally 0–1)

## Experiments for the first hardware sessions

Run each for ~30 s while idling, and share the debug report after each.

1. **Baseline:** preset *RPM only*, both experimental toggles off. This gives the max single-PID rate and the RTT distribution.
2. **RPM + Boost:** shows how rate is shared across 4 PIDs.
3. **Physical addressing** (`ATSH7E0`) on → reconnect. Hypothesis (UNVERIFIED): only the ECM answers, so the adapter doesn't wait for other ECUs.
4. **Response-count hint** (`010C1`) on → reconnect. Per the ELM327 documentation (v1.3+, as summarized by secondary sources) the adapter returns right after the expected number of replies instead of waiting out its timeout. This could be the single biggest win. Clones may not support it; Redline turns it off automatically if the adapter answers `?`.
5. Both on.

Interpreting the results:

- **High time-to-first-byte, small gap to completion** → ECU or adapter wait dominates (timeout, functional addressing). Experiments 3 and 4 target this.
- **Small time-to-first-byte, large gap to completion** → BLE fragmentation or connection interval dominates.
- Decode and publish times should be sub-millisecond. If they aren't, that's our bug.

Later experiments, only if the data justifies them: `ATS0` (fewer bytes), multi-PID requests (`010C0B11`, up to 6 PIDs per request on CAN; whether this ECU supports it is UNVERIFIED), and tuning `ATST`/`ATAT`.

Results go into DEVLOG.md. Redline shouldn't be described as faster than WrenchTime until these numbers exist.
