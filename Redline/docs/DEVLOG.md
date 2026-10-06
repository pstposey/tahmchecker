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

**Next:** the first hardware session (HARDWARE_TEST.md), then fill in BLE.md and record measured RTT and rates here.
