# Engineering log

## 2026-10-05: Phase 0–3 scaffold (pre-hardware)

**Repository.** `pstposey/tahmchecker` held only version files for an unrelated "TAHM checker". Redline lives entirely under `Redline/` so those files stay untouched. Moving Redline to its own repository later is straightforward (`git subtree split --prefix=Redline`).

**Environment.** Development happened in a Linux container without Xcode. The Swift 6.1 toolchain (Docker `swift:6.1-noble`) builds and tests `RedlineCore`. XcodeGen 2.46.0 was built from source to generate the `.xcodeproj`. The iOS app target (CoreBluetooth/SwiftUI) can't be compiled natively here. It's verified two ways:
- A GitHub Actions workflow (`.github/workflows/redline-ci.yml`) runs core tests on Linux and macOS and builds the app with Xcode for iOS. First run (`1e5ed66`): green, 1 warning, since fixed.
- Locally, the app sources are compiled against stub CoreBluetooth/SwiftUI modules that mirror the SDK signatures, in Swift 6 mode on toolchains 6.0, 6.1 and 6.2 (matching Xcode 16.0 through 26). This catches concurrency and access-control errors before CI.

**Decisions**
- Platform-neutral core package with strict Swift 6 concurrency, so the engine is testable without hardware.
- The ELM327 simulator sits behind the transport protocol, so simulation exercises the real parser, session and scheduler.
- No hardcoded Vgate UUIDs: GATT discovery plus an ELM `ATI` probe (BLE.md).
- Headers and spaces on during Milestone 1, for unambiguous parsing and readable logs (OBD.md).
- Pull-based scheduler with no request queue (POLLING.md).
- Physical addressing and the response-count hint are implemented behind toggles, **off** until measured.

**Research notes**
- The official ELM327 datasheet site and most reference sites were blocked by the egress policy. Behaviour was cross-checked with the Linux can327 driver docs and the python-OBD sources. Primary-source verification of the response-count suffix and default timing is still a TODO.
- Vgate GATT layout: no authoritative source found. Retail listings claim "ELM 2.3" and BT 5.x. Treated as unverified.

**Tests (at scaffold time):** 70 passing (`swift test`; 79 after the review fixes), covering the critical 115 kPa → 16.68 psi conversion, boost from MAP − BARO including vacuum, PID formula vectors, bitmask discovery, CAN and ISO-TP parsing, session timeout/late-response/resync safety, the scheduler's fairness and backoff, staleness, peaks, and end-to-end engine runs against the simulator.

## 2026-10-06: Adversarial review of the pre-hardware build

Four independent reviewers (BLE compile, UI compile, BLE runtime, core lifecycle), each meant to be followed by a skeptic that tried to refute their findings. The two runtime skeptic passes failed to run (usage limit). Instead, the core-lifecycle findings were each confirmed by a regression test that fails on the old code, and the BLE-runtime findings were checked by reading the code against CoreBluetooth's documented behaviour. A second adversarial pass over the fix commit followed.

- **Compile:** no errors in either app layer on Swift 6.0/6.1/6.2. Confirmed by the real Xcode CI build.
- **Fixed, with regression tests that fail on the old code:** `stop()`/`start()` race (a new connection could be closed and reported idle); metadata from a previous source leaking into the debug report; a bare-CR resync sent while a late reply was still arriving, which could shift every later response by one; cancellation during resync reported as "adapter unresponsive"; boost computed from a cached BARO after BARO was reported unsupported; measured rate polluted by outage gaps; reconnect backoff never resetting; response-count-hint fallback not reflected in the report; orderly stop logged as a disconnect.
- **Fixed in the BLE layer** (compile-verified; runtime needs hardware): Bluetooth power-off/reset not propagated to the transport (could hang a write) and stale peripherals reused after a reset; connect/notify timers from earlier attempts failing later ones; our own disconnect completing and failing an immediate reconnect; a link loss during probing misreported as "no ELM reply"; `open()` not cancellable during discovery/probing.
- **App:** the verified GATT link is bound to the adapter it was probed on; the keep-awake toggle applies immediately.

**Second pass (over the fix commit):** three reviewers plus skeptics. Three findings were confirmed and fixed: a link loss during resync was read as "no prompt", so the next command was written to a closed link (regression test added); a disconnect during the last probe candidate's cleanup was still misreported as "no ELM reply"; and the Bluetooth power-on wait wasn't cancellable. Three findings were refuted, including a deliberate trade-off: after a lost prompt, waiting out a late reply makes recovery slower (~3.4 s vs ~1.5 s), but it prevents responses from being attributed to the wrong PID.

**CI lesson:** two timing-based tests passed locally but failed or proved nothing on the loaded macOS runner. Both were rewritten to be event-driven or deterministic, checked to fail on the pre-fix code, and run repeatedly with all CPUs saturated. **Tests:** 80.

**Next:** the first hardware session (HARDWARE_TEST.md), then fill in BLE.md and record measured RTT and rates here.

## 2026-10-06: Read-only safety audit (before first vehicle connection)

Every outbound path was traced to its sink: two `transport.write` calls in the session, three `writeValue` calls and one `setNotifyValue` in the BLE transport. The full inventory and its effects are in SAFETY.md. Four independent auditors and a critic were planned. Only the sink tracer completed; the others hit the usage limit. Its findings were verified against the code and fixed.

- **No session-level gate.** Before this, only the console filtered input; the session would transmit anything it was handed. Now `ELM327Session.execute` checks every command against `CommandSafetyPolicy`: J1979 read services 01/02/03/06/07/09/0A, at most 7 bytes, plus a fixed AT allowlist. A refused command writes nothing.
- **`ATSP0` on every connection.** AT SP stores the protocol in the adapter's EEPROM, so each connection was a persistent write. It is now sent only when `ATDPN` shows the adapter isn't already automatic, and the debug report says so when it happens.
- **Line-break injection.** The gate first evaluated the normalized text, so `"010C\r04"` passed as `010C04`. Our own test caught it. The gate now evaluates the raw text, refuses line breaks and non-`[0-9A-Z@]` characters, and the session sends exactly the evaluated text.
- **Bare-CR resync.** The ELM327 repeats its last command on a bare CR. Before, that last command could be another app's (e.g. clear codes), or Redline's own `ATSP0`. The CR now requires an answered command from this session **and** that the last command is a read (an OBD read or an informational AT query). The old rule sent `ATE0, ATSP0, CR, ATRV` after a lost `ATSP0` prompt; the regression test shows it now stops at `ATSP0`.
- **BLE writes to unknown characteristics.** The `ATI` probe and CCCD writes are now limited to recognized ELM327 bridge layouts. An unknown layout fails with nothing written.
- **Tests that hold the boundary:** exhaustive 256-service check, dangerous AT commands, injection look-alikes, an end-to-end capture of everything the emulated adapter receives, and a source scan pinning every outbound call site. A new write path fails CI until it is reviewed. **Tests:** 98.

## 2026-10-06/07: OBDLink MX+ support (before any hardware test)

The owner switched the primary adapter to an OBDLink MX+ (the Vgate stays supported).

**Research** (MXPLUS.md has the details and sources):
- The MX+ is Bluetooth Classic v3.0. OBDLink says the CX is its only BLE adapter.
- iOS reaches it only through Apple's MFi **External Accessory** framework (`EASession` byte streams), never CoreBluetooth. iOS pairs and connects it after you press its Connect button in Settings › Bluetooth; apps can only open a session to an accessory iOS has already connected.
- Its MFi protocol string is not published. Redline declares two community-sourced candidates (`com.obdlink`, `com.scantool.stnobd`), both UNVERIFIED.
- Without the external-accessory background mode, sessions end when the app goes to the background.
- Some research angles (STN command behaviour, prior-art code) didn't complete because of the usage limit. Those items are marked UNVERIFIED rather than guessed.

**Design.**
- Both adapters are `OBDTransport`s, and nothing above the transport changed for the MX+.
- The stream logic is in core and unit-tested with mock streams: `AccessoryStreamTransport` for the open/close/cancel/disconnect lifecycle, `StreamPump` for Apple DTS's non-blocking stream pattern, and `StreamWriteBuffer` for partial writes.
- The iOS layer is thin. `ExternalAccessoryCenter` is `@MainActor` and handles discovery and notifications. `EAStreamSession` owns one run-loop thread per session and tears down in the reverse order of setup.
- Connect screen: separate MX+ and BLE sections.
- Debug report adds: transport type, name-based adapter identification with evidence, per-command initialization results with timings, the connection-state history, and the iOS version and device model.

**Read-only hardening.** The independent auditor from the previous round found that an ELM327 discards the character that interrupts or wakes it and may act on the rest of the line. For example, `0104` could leave `04` (clear codes), and `01101` could leave `1101` (ECU reset).
- The session no longer sends a bare CR. On uncertain state it probes with `ATI` (whose truncations aren't commands) before writing anything.
- The policy refuses any line whose truncation would be a clear or a parameterized non-read request. As a result, PID 04 and the response-count hint are gone, and the turbo dashboard uses absolute load instead.
- Raw input must be plain ASCII before normalization.
- `ATSP0` is skipped when `ATDPN` is unreadable.
- Retries while the vehicle is silent back off to 30 s.

**Adversarial review** (5 angles, each finding independently verified; 3 verifiers hit the usage limit, so those findings were checked by hand):
- **Medium:** with replies slower than the probe timeout, a late probe answer could pass as the newest probe's. The adapter would then be declared idle with one reply outstanding, and every later reply would be shifted by one. This was not a read-only break.
  - Fixed: one probe outstanding at a time, a probe reply must match the adapter's own `ATI` text, a silence window longer than the gaps between writes, and an unanswered-write count.
  - Three regression tests fail on the old code.
- **Low:**
  - Inventory regexes missed `pump?.send(` and nested-paren writes.
  - The vehicle-retry backoff survived a new connection.
  - Three tests were vacuous or racy: the poller's policy guard is now tested directly, the hint test checks what is actually sent, and a zero-margin timing race is fixed.
  - The BLE status read "Checking Bluetooth…" until a scan.
  - The foreground resume reopened the remembered adapter instead of the active MFi link.
  - An immediate reconnect could be refused while our own previous `EASession` was still being released; now Redline retries briefly.
  - All fixed.

**CI lesson:** a race in the end-to-end capture test (a poll from the previous preset still in flight) failed on the macOS runner only. It is fixed, and the suite was re-run 3× with all CPUs saturated.

**Tests:** 144, on Linux and macOS. The iOS app builds with `xcodebuild` (generic iOS device, unsigned) with no Swift warnings. Mocks are not hardware: everything MX+-specific listed in MXPLUS.md and HARDWARE_TEST.md still needs the physical adapter.
