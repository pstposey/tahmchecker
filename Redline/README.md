# Redline

Native iOS real-time vehicle telemetry, diagnostics and dashboard app.

**First target:** 2026 Mazda CX-30 Turbo (2.5 L Skyactiv-G turbo).

**Adapters:**
- **OBDLink MX+** (primary): MFi Bluetooth Classic, through Apple's External Accessory framework. Pair it once in iOS Settings.
- **Vgate iCar Pro 2S**: Bluetooth LE, found by scanning in Redline.

Both run the same ELM327 pipeline. See [docs/MXPLUS.md](docs/MXPLUS.md) for what's verified about the MX+ and what isn't.

**Current state: Milestone 1, ready for hardware testing.** The full pipeline exists and passes its tests against a simulated ELM327 and mocked accessory streams: adapter (MX+ or Vgate) → ELM327 initialization → supported-PID discovery → polling → decoding → live RPM, MAP, BARO, boost and coolant, plus a developer console. It has **not yet been run against either real adapter or the vehicle**. See [docs/HARDWARE_TEST.md](docs/HARDWARE_TEST.md).

## Layout

```
Redline/
  project.yml              XcodeGen spec (source of truth for the Xcode project)
  Redline.xcodeproj/       Generated project, committed so it opens directly
  App/                     iOS app: BLE (Vgate) and External Accessory (MX+) transports, SwiftUI views, composition
  Packages/RedlineCore/    Platform-independent engine (pure Swift; builds/tests on Linux + macOS)
  docs/                    Engineering documentation
```

`RedlineCore` holds everything that doesn't need Apple hardware: ELM327 protocol handling, OBD parsing and decoding, the scheduler, the telemetry store, units, boost, the MFi stream transport logic and the simulator. The app target adds CoreBluetooth, External Accessory and SwiftUI only.

## Build and run

Requirements: current Xcode (Swift 6 toolchain), iOS 17+ device for Bluetooth. The Simulator works for the built-in vehicle simulation, but not for Bluetooth or MFi accessories. Neither do iPhone apps running on a Mac.

1. Open `Redline/Redline.xcodeproj`.
2. Select the **Redline** target › Signing & Capabilities › choose your **Team** (the bundle ID is `com.pstposey.Redline`; change it if Xcode reports a conflict).
3. Run on your iPhone.
4. **Connect** tab › **Start simulation** to see the pipeline working without the car. For the MX+, pair it in iOS Settings › Bluetooth first, then tap it under **OBDLink MX+**. For the Vgate, use **Scan for Bluetooth LE adapters**.

Core tests:

```sh
cd Redline/Packages/RedlineCore
swift test
```

If you change `project.yml`, regenerate the project with [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen && cd Redline && xcodegen generate`.

## Principles (from the product brief)

- **No fake telemetry.** Every value carries provenance (`ECU_REPORTED`, `CALCULATED`, `ESTIMATED`). Unsupported PIDs show **Unsupported**, never 0. Supported channels with no sample yet show **--**. Old values are marked **STALE** using per-channel thresholds.
- **Boost = MAP − BARO**, using the vehicle's own BARO. Redline never assumes sea-level pressure; without BARO, boost is unavailable.
- **Read-only.** Every outbound command passes one allowlist enforced inside the ELM session: SAE J1979 read services only, no clear-DTC, reset, actuator, security, routine, write or flash services, and no raw CAN. See [SAFETY.md](docs/SAFETY.md).
- **Measure first.** Every request is timestamped; the Debug tab shows round-trip time, rates and failures. Speed claims need measurements behind them.
- **Simulation is always labelled** and runs through the same ELM327 parser and scheduler as a real adapter.
- **Local only.** No accounts, no analytics, no network.

## Documentation

| Doc | Contents |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Layers, concurrency model, data flow, key decisions |
| [docs/OBD.md](docs/OBD.md) | ELM327 init sequence and rationale, parsing, PID catalog, boost |
| [docs/MXPLUS.md](docs/MXPLUS.md) | OBDLink MX+: how it reaches iOS (MFi / External Accessory), what is verified and what isn't |
| [docs/BLE.md](docs/BLE.md) | Vgate BLE interface: what is verified and what isn't, and how discovery works |
| [docs/POLLING.md](docs/POLLING.md) | Scheduler design, latency instrumentation, experiments to run |
| [docs/SAFETY.md](docs/SAFETY.md) | **Read-only boundary**: every command Redline can transmit, what it can affect, and the tests that enforce it |
| [docs/HARDWARE_TEST.md](docs/HARDWARE_TEST.md) | Exact steps for the first in-car test |
| [docs/DEVLOG.md](docs/DEVLOG.md) | Engineering log |

## Roadmap

Phases follow the product brief: 0–3 (done, awaiting hardware), 4 PID discovery (done), 5–8 core telemetry, boost/units, polling optimization and the telemetry store (foundations done; the optimization phase needs hardware measurements). Next up: 9–11 dashboard, customization and peaks, then 12–13 diagnostics and readiness, then 14–16 logging, summaries and graphs. Later: 17 Mazda-enhanced PIDs (verified only), 18 CarPlay (research first: `docs/CARPLAY.md` gets written before any CarPlay code), and 19–20 Widgets, Live Activities and Now Playing.
