# Architecture

## Layers

```
┌──────────────────────────── App (iOS) ─────────────────────────────┐
│ SwiftUI views (Live / Connect / Debug)    AppModel (composition)    │
│ Vgate:  BLECentral + BLEOBDTransport (CoreBluetooth, GATT)          │
│ MX+:    ExternalAccessoryCenter + EAStreamSession (External         │
│         Accessory: EASession streams on their own run-loop thread)  │
└──────────────┬──────────────────────────────────────▲──────────────┘
               │ OBDTransport (bytes)                 │ observes
┌──────────────▼──────────── RedlineCore ─────────────┴──────────────┐
│ TelemetryEngine (@MainActor)  — lifecycle, reconnect, presets       │
│   ├─ ELM327Session (actor)    — serialized commands, framing,       │
│   │                              timeouts, resync, raw log          │
│   ├─ ELMInitializer           — init sequence, vehicle detection,   │
│   │                              PID support discovery              │
│   ├─ PollingWorker (actor)    — request loop, decode, backoff       │
│   │    └─ PollScheduler (value type) — what to request next         │
│   └─ TelemetryStore (@MainActor, @Observable)                       │
│        └─ ChannelState × N (@Observable) — value, peak, stale, rate │
│ OBDFrameParser · OBDResponseDecoder · StandardPIDs (declarative)    │
│ Units · MeasurementPresenter · BoostCalculator · PeakTracker        │
│ PerformanceMonitor · CommLog · CommandSafetyPolicy                  │
│ AccessoryStreamTransport + StreamPump (MFi stream transport, used   │
│   by the MX+) · AccessorySelector · AdapterCatalog                  │
│ SimulatedELM327Transport + SimulatedVehicle                         │
└────────────────────────────────────────────────────────────────────┘
```

**Rule:** views read `TelemetryStore`/`TelemetryEngine` state only. They never issue OBD commands; the one exception is the developer console, which goes through `TelemetryEngine.sendConsoleCommand` and `CommandSafetyPolicy`.

## Why a separate package

There's no Xcode in the cloud development environment, and real-car tests happen only occasionally. Everything that can be platform-neutral lives in `RedlineCore`, which compiles and runs its tests on Linux (Swift 6.1, strict concurrency) and on macOS. The iOS target only adds CoreBluetooth, External Accessory and SwiftUI.

**Adapters live at the transport boundary.** Both adapters speak the same ELM327-style text protocol; only the link differs.
- The Vgate is a BLE GATT peripheral.
- The OBDLink MX+ is an MFi Bluetooth Classic accessory reached through `EASession` byte streams (MXPLUS.md).
- Each is an `OBDTransport`. The session, initializer, scheduler, decoders, store and UI don't know which one is connected.
- The MX+'s stream handling (open tracking, partial writes, flow control, disconnects) is in core (`AccessoryStreamTransport`, `StreamPump`), so it is unit-tested with mock streams. Only the thin EA wrapper is iOS-only. That also keeps the engine reusable for future displays (CarPlay, iPad, an external display, a Mac dashboard).

## Data flow for one sample

1. `PollScheduler.next(now:)` picks a PID. It's pull-based, so no queue exists.
2. `PollingWorker` calls `ELM327Session.execute("010C")`.
3. The session acquires its FIFO gate, writes `010C\r`, and waits for the `>` prompt. The time just before the write is recorded as `sentAt`.
4. The transport timestamps each chunk as it arrives and yields bytes into an ordered `AsyncStream`: `BLEOBDTransport` in the CoreBluetooth notification callback, `StreamPump` in the input stream's has-bytes event (MX+).
5. `ELMResponseFramer` completes the response at `>`. That chunk's receive time becomes `completedAt`.
6. `ELMResponse` classifies the lines (echo, SEARCHING..., NO DATA, errors). `OBDFrameParser` splits CAN headers and reassembles ISO-TP frames per ECU. `OBDResponseDecoder` checks the service/PID echo and the byte count, then applies the declarative formula and the plausibility check.
7. The worker yields a `TelemetrySample` with `SampleTiming(requestedAt, receivedAt, decodedAt)` into a bounded `AsyncStream`. It never waits for the UI.
8. A main-actor consumer applies the sample to `TelemetryStore`. Only the affected `ChannelState` changes, so only views showing that channel re-render. A MAP sample also produces a calculated boost sample if a valid BARO exists.
9. `PerformanceMonitor` records RTT, time to first byte, decode time and publish latency.

## Concurrency model

| Component | Isolation | Why |
|---|---|---|
| CoreBluetooth objects, `BLECentral`, `BLEOBDTransport` | Confined to one serial `DispatchQueue` (CoreBluetooth's delegate queue) | CB requires its queue; keeps BLE off the main thread |
| `EAAccessoryManager`, `EAAccessory`, `ExternalAccessoryCenter` | `@MainActor` | EA posts notifications on the main thread; only Sendable `AccessoryDescriptor` snapshots leave it |
| `EASession` streams, `StreamPump` | One dedicated thread with its own run loop per session (`StreamThread`) | Streams must be scheduled on a running run loop and touched only from its thread (Apple DTS); never a GCD queue or Swift-concurrency executor |
| `AccessoryStreamTransport` | Lock-protected state (`Locked`) | Bridges the stream thread and the session actor; generation counter so a stale link can't affect a new one |
| `ELM327Session` | actor + explicit FIFO gate | The ELM327 is half-duplex: exactly one command in flight. Actor reentrancy alone does not serialize across `await`, hence the gate |
| `PollingWorker` | actor | Owns the scheduler; never touches the main actor |
| `TelemetryEngine`, `TelemetryStore`, `ChannelState` | `@MainActor @Observable` | UI state; per-channel objects keep invalidation scoped |
| `CommLog`, `PerformanceMonitor` | lock-protected (`Locked`) | Written on the hot path, read by the debug UI; no actor hops |

Swift 6 language mode with strict concurrency is enabled for both the package and the app.

## Key decisions

- **No hardcoded BLE UUIDs.** The GATT table is discovered at runtime, and the link is verified with an ELM probe. See BLE.md.
- **Headers on (ATH1), spaces on (ATS1).** This identifies the responding ECU and keeps 11-bit/29-bit headers unambiguous. Byte savings from ATS0 are a measured experiment for later, not an assumption. See OBD.md.
- **Pull-based scheduler.** There's no request queue to grow or go stale, and bandwidth is shared in proportion to 1/target-interval. See POLLING.md.
- **Simulation at the byte level.** The simulator is an ELM327 emulator behind `OBDTransport`, so simulation exercises the real parser, session and scheduler. Its transport kind is `.simulated`, and the UI shows a SIMULATION badge.
- **Declarative PIDs.** `PIDFormula.linear(byteOffset:byteCount:scale:offset:)` covers every standard PID used so far. One evaluation function is audited, and the simulator encodes with the exact inverse.
- **Read-only by construction.**
  - `ELM327Session.execute` refuses, and never writes, any command `CommandSafetyPolicy` doesn't allowlist, whoever the caller is. That includes lines whose truncation would be a state-changing request.
  - The session never writes to an adapter that might be busy: on uncertain state it probes with `ATI`, and it never sends a bare CR.
  - The BLE probe only writes to recognized ELM327 bridge layouts. The MX+ transport adds no command source.
  - Full inventory: SAFETY.md.
- **Persistence:** one JSON blob in `UserDefaults` (`AppSettings`). Dashboards will need a richer store in Phase 10.

## Error handling summary

| Situation | Behaviour |
|---|---|
| Bluetooth off or unauthorized | `open` throws; status shows the reason; reconnect loop retries with backoff |
| MX+ not paired, not connected, or its protocol not declared | `open` waits up to 30 s for a matching accessory, then fails with the reason (no accessory / not yet authenticated / unsupported protocols, listed in the log); reconnect loop retries |
| MX+ session refused by iOS | "iOS refused a session…" (another app holds the adapter); retried with backoff |
| Adapter disconnects | Transport yields `.closed`; session fails the pending request; engine shows Disconnected → Reconnecting (backoff 2, 4, 8, then 15 s) |
| Ignition off / ECU silent | `0100` returns NO DATA, UNABLE TO CONNECT, etc. → "Vehicle unavailable", retried every 3 s. Mid-stream, 12 consecutive no-response answers with no success for 3 s → re-initialize and wait |
| A PID stops answering | Scheduler suspends it with exponential backoff (1 s → 30 s); channel shows unavailable with the reason |
| Response timeout | Session marks itself out of sync, discards the late response, and confirms the adapter is idle (ATI probe) before the next command. 4 consecutive timeouts or 4 unclear probes → adapter unresponsive → reconnect |
| Malformed / implausible data | Logged with raw bytes; the sample is marked invalid and never displayed; polling continues |
| App backgrounded (Vgate, BLE) | Polling paused (no Bluetooth background mode in V1) |
| App backgrounded (MX+, MFi) | The EA session is closed cleanly (iOS would end it anyway without the external-accessory background mode). On return to the foreground the accessory list is re-read and a fresh session opens |
