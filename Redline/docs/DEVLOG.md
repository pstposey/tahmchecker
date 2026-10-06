# Engineering log

## 2026-10-05: Phase 0–3 scaffold (pre-hardware)

**Repository.** `pstposey/tahmchecker` held only version files for an unrelated "TAHM checker". Redline lives entirely under `Redline/` so those files stay untouched. Moving Redline to its own repository later is straightforward (`git subtree split --prefix=Redline`).

**Environment.** Development happened in a Linux container without Xcode. The Swift 6.1 toolchain (Docker `swift:6.1-noble`) builds and tests `RedlineCore`. XcodeGen 2.46.0 was built from source to generate the `.xcodeproj`. The iOS app target (CoreBluetooth/SwiftUI) **could not be compiled here**. A GitHub Actions workflow (`.github/workflows/redline-ci.yml`) builds it on macOS; the first CI run is pending repository push access.

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

**Tests:** 70 passing (`swift test`), covering the critical 115 kPa → 16.68 psi conversion, boost from MAP − BARO including vacuum, PID formula vectors, bitmask discovery, CAN and ISO-TP parsing, session timeout/late-response/resync safety, the scheduler's fairness and backoff, staleness, peaks, and end-to-end engine runs against the simulator.

**Next:** the first hardware session (HARDWARE_TEST.md), then fill in BLE.md and record measured RTT and rates here.
