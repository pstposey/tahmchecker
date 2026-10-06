# Read-only safety boundary (Milestone 1)

Redline Milestone 1 is **strictly read-only toward the vehicle**. This document lists **everything Redline can transmit**, what each item can affect, and how the boundary is enforced and tested. If you add any outbound path, update this file and the tests in `ReadOnlySafetyTests.swift`. Those tests are designed to fail until you do.

Status labels: **ENFORCED** = blocked in code and covered by tests. **SPEC** = follows from SAE J1979 / ISO 14229 / ELM327 behaviour as documented; not hardware-verified on this vehicle.

## 1. Where bytes can leave the app

There are exactly four outbound sinks (pinned by `OutboundSurfaceInventoryTests`):

| Sink | File | What it sends |
|---|---|---|
| `transport.write(command + CR)` | `ELM327Session.execute` | Every ELM/OBD command, after the policy gate |
| `transport.write(CR)` | `ELM327Session.resynchronize` | Bare CR used to resync after a timeout (see §4) |
| `CBPeripheral.writeValue` (3 call sites) | `BLEOBDTransport` | The `ATI\r` probe, plus the write pump that carries the session's bytes |
| `CBPeripheral.setNotifyValue` | `BLEOBDTransport` | GATT notification subscribe/unsubscribe (CCCD write) |

`ELM327Session.execute` is called from only three places: `ELMInitializer` (initialization, vehicle detection, PID discovery, options), `PollingWorker` (live data), and `TelemetryEngine.sendConsoleCommand` (developer console). The only transports are `BLEOBDTransport` (real adapter) and `SimulatedELM327Transport` (in-process emulator; never reaches hardware).

## 2. Complete inventory of transmittable commands

### 2a. Vehicle bus: OBD requests (the adapter transmits these as CAN frames)

Addressed to the functional OBD ID `7DF` (all emission ECUs), or to `7E0` (engine ECU) if the *Physical addressing* option is on.

| Request | When | Effect on vehicle |
|---|---|---|
| `0100`, then `0120` … `01E0` as advertised | Every connection (support discovery) | **Read only** (J1979 service 01 "PIDs supported") |
| `01` + PID (`04 05 06 07 0A 0B 0C 0D 0E 0F 10 11 1F 22 23 24 2F 33 34 42 43 44 45 46 47 49 4A 4C 59 5A 5C 5E`), optional trailing `1` | Continuous polling. Only supported PIDs in the selected preset are polled | **Read only** (service 01 current data). The trailing digit is an adapter instruction and is not sent on the bus |
| Service `01`, `02`, `03`, `06`, `07`, `09`, `0A`, ≤ 7 bytes | Only when typed into the developer console | **Read only** (current data, freeze frame, stored/pending/permanent DTCs, monitor test results, vehicle info) |

Nothing else can be transmitted (**ENFORCED**). Explicitly refused, with tests:
- `04` (clear DTCs, freeze frame and readiness monitors) and `08` (on-board control, i.e. actuators).
- Every ISO 14229 / KWP2000 service: session control `10`, ECU reset `11`, clear `14`, `19`, `22`, `23`, SecurityAccess `27`, CommunicationControl `28`, `2C`, WriteDataByIdentifier `2E` (coding/configuration/adaptations), I/O control `2F`/`30`, RoutineControl `31`, download/upload/transfer `34`–`38` (reflashing), `3B`, WriteMemoryByAddress `3D`, TesterPresent `3E`, ControlDTCSetting `85`, LinkControl `87`, and all other service bytes (all 256 values are exhaustively tested).

Protocol-level traffic the adapter generates on its own (**SPEC**):
- The first OBD request after automatic-protocol selection makes the ELM327 *search* protocols. On non-CAN protocols that means the standard OBD initialization handshakes (ISO 9141 5-baud init / KWP fast init on the K-line, J1850 requests). These are defined by the protocols for reading, not ECU state changes. The CX-30 is expected to answer on CAN; the debug report shows the protocol actually found.
- When a response spans several CAN frames (e.g. a console `0902` VIN read), the adapter sends ISO-TP **flow-control** frames. These are part of the reading protocol.
- On ISO 9141/KWP protocols only, ELM327s send periodic keep-alive messages by default. Not applicable on CAN.

### 2b. Adapter: ELM327 AT commands (configure the adapter only; never sent on the vehicle bus)

| Command | When | Persistence |
|---|---|---|
| `ATZ` | Every (re)initialization | Volatile: resets the adapter to its defaults |
| `ATE0`, `ATL0`, `ATS1`, `ATH1` | Every initialization | Volatile: echo/linefeed/spaces/headers formatting |
| `ATI`, `AT@1`, `ATRV`, `ATDPN`, `ATDP` | Initialization, vehicle detection, BLE probe (`ATI`) | None (read identification, voltage, protocol) |
| `ATSP0` | **Only if** `ATDPN` shows the adapter is not already set to automatic | **PERSISTENT (adapter)**: AT SP stores the protocol as the adapter's power-on default. This restores the factory default "automatic". It's recorded in `AdapterInfo.persistentAdapterWrites` and in the debug report |
| `ATSH7E0` (allowlist: `ATSH7E0`–`ATSH7E7`) | Only if *Physical addressing* is switched on (off by default) | Volatile: selects which ECU receives the read requests |
| `ATI`, `AT@1`, `ATRV`, `ATDP`, `ATDPN`, `ATCS`, `ATIGN` | Only when typed into the console | None (informational) |

Refused (**ENFORCED**, tested), including:
- Adapter EEPROM writes: `ATPP…`, `ATSD`, `ATCV`.
- Baud rate: `ATBRD`, `ATBRT`. Low power: `ATLP`.
- Any fixed or stored protocol other than automatic: `ATSP6`, `ATSPA6`, `ATTP…`.
- Arbitrary CAN headers: `ATSH7DF`, `ATSH000`, 29-bit headers.
- Raw-frame and formatting controls: `ATCAF0`, `ATAL`, `ATR0`, `ATRTR`, `ATV1`.
- Filters and flow control: `ATCF`, `ATCM`, `ATCRA`, `ATFC…`.
- Monitor modes: `ATMA`, `ATMR`, `ATMT`, `ATBD`.
- Bus initialization, wake-up and keep-alive: `ATSW`, `ATWM`, `ATFI`, `ATSI`, `ATBI`, `ATKW`, `ATIB`, `ATIIA`.
- Defaults and warm start: `ATD`, `ATWS`.
- Non-ELM extensions (`ST…`, `VT…`).

### 2c. Bluetooth / GATT (adapter radio; never the vehicle)

| Action | When | Notes |
|---|---|---|
| Scan, connect, disconnect, service/characteristic discovery | Connecting | Reading the GATT table writes nothing |
| CCCD write (subscribe/unsubscribe notifications) | Probing a candidate | **Only** on a recognized ELM327 bridge layout or the pair previously verified on this adapter |
| `ATI\r` probe write | Probing | Same gate as above; at most 4 pairs |
| Session bytes | After verification | Only to the characteristic pair that answered the probe |

Unrecognized vendor characteristics, which could be configuration, device-name or firmware-update endpoints, get **no writes at all**. If no recognized layout exists, `open()` fails with "Unrecognized adapter Bluetooth layout — nothing was written" and logs the GATT table (**ENFORCED**, `BLEProbeGatingTests`). The recognized layouts are community-reported and **UNVERIFIED** for the Vgate iCar Pro 2S (see BLE.md).

## 3. What could alter persistent or operational state

| Target | Persistent change possible? | Operational effect |
|---|---|---|
| **Vehicle ECUs** | **No.** Only J1979 read services can be transmitted | While connected, polling adds a few diagnostic frames per second to the diagnostic bus. ECUs answer read requests normally. With the ignition off, Redline retries `0100` every ~3 s while the app is in the foreground and connected; on some vehicles bus traffic can keep a gateway awake, so don't leave the app polling with the ignition off for long periods. iOS suspends Redline in the background and polling pauses |
| **ELM327 adapter** | Only `ATSP0`, and only when the stored protocol isn't already automatic (it restores the factory default). Reported in the debug report | `ATZ` reset and formatting/header settings are volatile and re-applied every connection |
| **Adapter Bluetooth** | CCCD subscription state may be remembered by the BLE stack for bonded devices (standard GATT behaviour) | None |

## 4. How it's enforced

1. **One gate for every caller.** `ELM327Session.execute` evaluates the caller's raw text with `CommandSafetyPolicy.evaluateTransmission` before taking the adapter. A refused command throws `.commandRefused`, is logged as `REFUSED by read-only policy`, and **nothing is written**. The text sent is exactly the normalized text that was evaluated.
2. **Allowlists only**: 7 read services, at most 7 bytes (one CAN frame), and a fixed AT-command set. Line breaks, control characters and non-ASCII look-alikes are refused, so one string can never become two adapter commands.
3. **Stricter console.** The console adds its own allowlist: informational AT commands only, plus the 7 read services.
4. **Bare-CR resync safety.** The ELM327 repeats its *last* command when it receives a bare CR. Redline sends one only after the adapter has answered at least one command from this session, and only if that command is repeat-safe. So the adapter can never be made to repeat a command left over from another app, e.g. a clear-codes request.
5. **BLE write gating**, described in §2c.
6. **No path bypasses the session.** The developer console and every engine path go through `TelemetryEngine` → `ELM327Session`. The session object isn't exposed to the UI.

## 5. Tests that hold the boundary

`Packages/RedlineCore/Tests/RedlineCoreTests/ReadOnlySafetyTests.swift`:
- `onlySAEReadServicesAreTransmittable`: exhaustive over all 256 service bytes, for both the transmission gate and the console.
- `writeAndControlServicesAreRefused`: clear DTCs, actuator control, ECU reset, SecurityAccess, RoutineControl, write-by-identifier, memory writes, download/transfer, communication/DTC-setting control, and more.
- `configurationRawCANAndBusCommandsAreRefused`: EEPROM, baud, raw-CAN, filter, monitor, wake-up and keep-alive AT commands.
- `transmittableAdapterCommandsAreExactlyTheDocumentedSet`: the AT allowlist equals this document.
- `injectionAndLookalikeInputsAreRefused`: CR/LF/U+2028/NUL/zero-width/full-width input, over-long requests, malformed suffixes.
- `sessionRefusesAndWritesNothing`: every dangerous command sent straight to the session; asserts zero bytes reach the transport.
- `everyBuiltInCommandIsTransmittable`: every command the code can generate passes the gate and is repeat-safe.
- `everythingTheAdapterReceivesIsAllowed`: end to end. The real engine runs with all presets and both options, plus hostile console input; every command the emulated adapter received is checked. No `ATSP0` is sent when the adapter is already automatic.
- `protocolIsStoredOnlyWhenAdapterIsNotAlreadyAutomatic`: the single persistent adapter write happens only when needed and is reported.
- `bareCRNeverSentBeforeFirstAnsweredCommand`.
- `BLEProbeGatingTests`: unknown characteristics are never probed.
- `OutboundSurfaceInventoryTests`: scans the source tree, pinning the exact outbound call sites and checking every command literal against the gate. A new write path fails CI until it is reviewed.

## 6. Out of scope

Clearing DTCs (service 04) will be a separate, explicitly confirmed feature in the diagnostics phase. It is not reachable in Milestone 1. Manufacturer (Mazda) service-22 reads will only be added after each identifier is verified, and only as reads.
