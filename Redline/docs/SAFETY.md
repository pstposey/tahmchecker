# Read-only safety boundary (Milestone 1)

Redline Milestone 1 is **strictly read-only toward the vehicle**, with either supported adapter: the Vgate iCar Pro 2S (Bluetooth LE) or the OBDLink MX+ (MFi / External Accessory). This document lists **everything Redline can transmit**, what each item can affect, and how the boundary is enforced and tested. If you add any outbound path, update this file and `ReadOnlySafetyTests.swift`; those tests are built to fail until you do.

Status labels: **ENFORCED** = blocked in code and covered by tests. **SPEC** = follows from SAE J1979 / ISO 14229 / ELM327 behaviour as documented; not hardware-verified on this vehicle or adapter.

## 1. Where bytes can leave the app

All ELM/OBD traffic, for both adapters, leaves through **one** function: `ELM327Session.transmit`. It re-checks the policy and writes exactly one command line plus CR. Below it, each transport only moves those bytes. The sinks are pinned by `OutboundSurfaceInventoryTests`.

| Sink | File | What it sends |
|---|---|---|
| `transport.write(command + CR)` (1 site) | `ELM327Session.transmit` | Every ELM/OBD command, and the `ATI` resync probe (§4), after the policy gate |
| `CBPeripheral.writeValue` (3 sites) | `BLEOBDTransport` (Vgate) | The `ATI\r` link probe, plus the write pump that carries the session's bytes |
| `CBPeripheral.setNotifyValue` (1 site) | `BLEOBDTransport` (Vgate) | GATT notification subscribe/unsubscribe (CCCD write) |
| `OutputStream.write(_:maxLength:)` (1 site) | `StreamPump` (MX+) | Only bytes handed to `StreamPump.send`, whose only caller is `AccessoryStreamTransport.write`, whose only caller is the session |
| `EASession(accessory:forProtocol:)` (1 site) | `ExternalAccessoryCenter` (MX+) | Opens the MFi session (no payload; iOS handles the iAP2 link) |

- **Callers of `ELM327Session.execute`:** `ELMInitializer` (one `exchange` helper for initialization, vehicle detection, PID discovery and options), `PollingWorker` (live data) and `TelemetryEngine.sendConsoleCommand` (developer console).
- **Transports:** `BLEOBDTransport`, `AccessoryStreamTransport` and `SimulatedELM327Transport` (an in-process emulator; never reaches hardware).

## 2. Complete inventory of transmittable commands

### 2a. Vehicle bus: OBD requests (the adapter transmits these as CAN frames)

Addressed to the functional OBD ID `7DF` (all emission ECUs), or to `7E0` (engine ECU) if *Physical addressing* is on.

| Request | When | Effect on vehicle |
|---|---|---|
| `0100`, then `0120` … `01E0` as advertised | Every connection (support discovery) | **Read only** (J1979 service 01 "PIDs supported") |
| `01` + PID (`05 06 07 0A 0B 0C 0D 0E 0F 10 11 1F 22 23 24 2F 33 34 42 43 44 45 46 47 49 4A 4C 59 5A 5C 5E`) | Continuous polling; only supported PIDs in the selected preset | **Read only** (service 01 current data) |
| Service `01`, `02`, `03`, `06`, `07`, `09`, `0A`, ≤ 7 bytes, passing the truncation rule (§4) | Only when typed into the developer console | **Read only** (current data, freeze frame, stored/pending/permanent DTCs, monitor results, vehicle info) |

Nothing else can be transmitted (**ENFORCED**). Explicitly refused, with tests:

- `04` (clear DTCs, freeze frame and readiness monitors) and `08` (on-board control, i.e. actuators).
- Every ISO 14229 / KWP2000 service, including:
  - session control `10`, ECU reset `11`, clear `14`, `19`, `22`, `23`
  - SecurityAccess `27`, CommunicationControl `28`, `2C`
  - WriteDataByIdentifier `2E` (coding/configuration/adaptations), I/O control `2F`/`30`, RoutineControl `31`
  - download/upload/transfer `34`–`38` (reflashing), `3B`, WriteMemoryByAddress `3D`, TesterPresent `3E`
  - ControlDTCSetting `85`, LinkControl `87`
- All other service bytes (all 256 values are exhaustively tested).
- **Since the truncation rule (§4):**
  - **PID 04** (`0104`, engine load) is never requested; its last two characters are `04`. The turbo dashboard uses absolute load (PID 43) instead.
  - The **response-count hint** (`010C1`) is always off, because a truncated `010C1` is `10C1`.
  - Multi-PID and other 3+ byte service 01/02 requests are refused, because truncated they become a service-1x/2x request with parameters.

Protocol-level traffic the adapter generates on its own (**SPEC**):

- **Protocol search.** With the protocol on automatic, an unanswered `0100` (ignition off) makes the adapter *search* protocols. On a CAN car that means initialization attempts on every OBD protocol, including CAN frames at a rate different from the bus's.
  - That's the reading protocol's own discovery, not a request to change ECU state. It is still bus traffic, and it can keep modules awake.
  - Redline's retry interval while the vehicle stays silent grows from 3 s to 10 s, then to 30 s (`TelemetryEngine.vehicleRetryDelay`).
  - Recommendation: don't leave Redline connected for long with the ignition off.
- **ISO-TP flow control.** When a response spans several CAN frames (e.g. a console `0902` VIN read), the adapter sends flow-control frames. These are part of reading.
- **Keep-alives on ISO 9141/KWP only.** Not on CAN.

### 2b. Adapter: ELM327/STN AT commands (configure the adapter only; never sent on the vehicle bus)

| Command | When | Persistence |
|---|---|---|
| `ATZ` | Every (re)initialization | Volatile: resets the adapter to its defaults |
| `ATE0`, `ATL0`, `ATS1`, `ATH1` | Every initialization | Volatile: echo/linefeed/spaces/headers formatting |
| `ATI`, `AT@1`, `ATRV`, `ATDPN`, `ATDP` | Initialization, vehicle detection, the BLE link probe (`ATI`) and the resync probe (`ATI`) | None (read identification, voltage, protocol) |
| `ATSP0` | **Only if** `ATDPN` reads back a protocol setting that is **not** automatic; never if `ATDPN` is unreadable | **PERSISTENT (adapter)** on the ELM327: AT SP stores the protocol as the power-on default. This restores the factory default "automatic". Whether the MX+'s STN chip stores it too is UNVERIFIED. Recorded in `AdapterInfo.persistentAdapterWrites` and the debug report |
| `ATSH7E0` (allowlist: `ATSH7E0`–`ATSH7E7`) | Only if *Physical addressing* is on (off by default) | Volatile: selects which ECU receives the read requests |
| `ATI`, `AT@1`, `ATRV`, `ATDP`, `ATDPN`, `ATCS`, `ATIGN` | Only when typed into the console | None (informational) |

Refused (**ENFORCED**, tested), including:

- Adapter EEPROM writes: `ATPP…`, `ATSD`, `ATCV`.
- Baud rate `ATBRD`/`ATBRT`, low power `ATLP`.
- Any fixed or stored protocol other than automatic: `ATSP6`, `ATSPA6`, `ATTP…`.
- Arbitrary CAN headers: `ATSH7DF`, `ATSH000`, 29-bit headers.
- Raw-frame and formatting controls: `ATCAF0`, `ATAL`, `ATR0`, `ATRTR`, `ATV1`.
- Filters and flow control: `ATCF`, `ATCM`, `ATCRA`, `ATFC…`.
- Monitor modes: `ATMA`, `ATMR`, `ATMT`, `ATBD`.
- Bus initialization, wake-up and keep-alive: `ATSW`, `ATWM`, `ATFI`, `ATSI`, `ATBI`, `ATKW`, `ATIB`, `ATIIA`.
- `ATD`, `ATWS`.
- **Every STN/OBDLink extension (`ST…`)**, which covers sleep and power configuration, protocol switching, monitoring, raw CAN, and firmware/bootloader. Also `VT…`.

### 2c. Bluetooth / accessory link (adapter radio; never the vehicle)

| Adapter | Action | When | Notes |
|---|---|---|---|
| Vgate (BLE) | Scan, connect, disconnect, GATT discovery | Connecting | Reading the GATT table writes nothing |
| Vgate (BLE) | CCCD write; `ATI\r` probe write | Probing a candidate | **Only** on a recognized ELM327 bridge layout or the pair previously verified on this adapter; at most 4 pairs |
| Vgate (BLE) | Session bytes | After verification | Only to the characteristic pair that answered the probe |
| MX+ (MFi) | Pairing and connection | Done by **iOS** (Settings › Bluetooth) | Redline has no API to pair or connect; iOS runs MFi authentication |
| MX+ (MFi) | `EASession` open/close | Connect / disconnect / background | One session at a time, only for a protocol Redline declares and the accessory advertises |
| MX+ (MFi) | Session bytes | After both streams open | Only what the ELM session transmits; nothing is probed or written by the transport itself |

For the Vgate, unrecognized vendor characteristics, which could be configuration, device-name or firmware-update endpoints, get **no writes at all**. If no recognized layout exists, `open()` fails with "Unrecognized adapter Bluetooth layout — nothing was written" (**ENFORCED**, `BLEProbeGatingTests`).

## 3. What could alter persistent or operational state

| Target | Persistent change possible? | Operational effect |
|---|---|---|
| **Vehicle ECUs** | **No.** Only J1979 read services can be transmitted, and no allowed line truncates into anything else | While connected, polling adds a few diagnostic frames per second. With the ignition off, unanswered `0100` probes trigger the adapter's protocol search (§2a). Retries slow to every 30 s, but bus traffic can keep modules awake, so don't leave Redline connected with the ignition off for long periods |
| **Adapter (either)** | Only `ATSP0`: only when the stored protocol reads back as not automatic, and it restores the factory default. Reported in the debug report | `ATZ` reset and the formatting/header settings are volatile and re-applied on every connection |
| **Adapter Bluetooth** | Vgate: CCCD subscription state may be remembered by the BLE stack (standard GATT). MX+: pairing is done by you in iOS Settings, not by Redline | None |

## 4. How it's enforced

1. **One gate for every caller.**
   - `ELM327Session.execute` evaluates the caller's raw text with `CommandSafetyPolicy.evaluateTransmission` before taking the adapter. A refused command throws `.commandRefused`, is logged as `REFUSED by read-only policy`, and **nothing is written**.
   - `transmit`, the only writer, checks the policy again, and the text sent is exactly the normalized text that was evaluated.
2. **Allowlists only.**
   - OBD: 7 read services, at most 7 bytes (one CAN frame). AT: a fixed command set.
   - Raw input must be plain ASCII letters, digits, `@` and spaces **before** normalization. Line breaks, control characters and look-alikes (`ı`, `ß`, `ﬀ`, full-width digits) are refused instead of translated, so one string can never become two adapter commands.
3. **Truncation rule (defense in depth).**
   - An ELM327 discards the character that interrupts it, or wakes it from low power. What firmware does with the rest of that line is not documented anywhere Redline could verify.
   - So no allowed line may contain, after any number of leading characters are lost:
     - a service `04` request (in any form; clear needs no parameters), or
     - a non-read request **with parameters**, e.g. `1101` ECU reset or `10C1` diagnostic session.
   - A lone non-read service byte has no parameters, and ECUs reject it.
   - An exhaustive test checks every allowed service/PID line.
4. **The session never writes to an adapter that might be busy.**
   - After a timeout, cancellation or failed write, the session waits for the late prompt.
   - If the state is still unknown, it sends the probe `ATI`. Its truncations, `TI` and `I`, are not commands, and any partial line left in the adapter plus `ATI` isn't hex either.
   - It sends the next real command only after the probe's own answer (one probe at a time, matching the adapter's `ATI` text) followed by silence longer than the gaps between this episode's writes.
   - **A bare CR is never sent**, because an idle ELM327 repeats its last command on one, and that command could be another app's.
5. **Stricter console.** The console adds its own allowlist: informational AT commands only, plus the read services.
6. **BLE write gating** as described in §2c. **The MX+ transport adds no command source**: `StreamPump` writes only what `send` was given.
7. **No path bypasses the session.** The developer console and every engine path go through `TelemetryEngine` → `ELM327Session`. The session object isn't exposed to the UI.

## 5. Tests that hold the boundary

`Packages/RedlineCore/Tests/RedlineCoreTests/ReadOnlySafetyTests.swift`, plus session and stream tests:

- **Services:** `onlySAEReadServicesAreTransmittable` is exhaustive over all 256 service bytes. `writeAndControlServicesAreRefused` covers named write/control/clear/reset/security/routine/flash requests.
- **Adapter commands:** `configurationRawCANAndBusCommandsAreRefused`; `transmittableAdapterCommandsAreExactlyTheDocumentedSet`.
- **Input:** `injectionAndLookalikeInputsAreRefused` covers CR/LF/U+2028/NUL/zero-width/full-width/`ı`/`ß`/`ﬀ`/tab, over-long requests and malformed suffixes.
- **Truncation:** `linesThatTruncateIntoStateChangingRequestsAreRefused` (the audit's examples); `noTransmittableLineTruncatesIntoAStateChangingRequest` (exhaustive); `theResyncProbeIsTransmittableAndHarmlessWhenTruncated`.
- **Session gate:** `sessionRefusesAndWritesNothing`, `sessionTransmitsExactlyTheEvaluatedText`, `everyBuiltInCommandIsTransmittable`.
- **Resync:**
  - `resyncNeverRepeatsACommandAndNeverSendsABareCR`
  - `silentAdapterIsProbedThenDeclaredUnresponsive`
  - `strayPromptAfterProbeTriggersAnotherProbe` (the audit's crossed-prompt race)
  - `unclearProbeRepliesAreRetried`
  - `failedWriteForcesAProbeBeforeTheNextCommand`
  - `slowRepliesNeverShiftResponsesByOne`, `lateAnswerInProbeSlotIsSkippedNotTrusted`, `probeReplyMustMatchTheAdaptersIdentification` (review findings)
- **End to end:**
  - `everythingTheAdapterReceivesIsAllowed`: the real engine with all presets, both options and hostile console input.
  - `engineStreamsAndEveryTransmittedCommandIsAllowed`: the same check over the MX+ stream transport, with forced partial writes.
- **Adapter persistence:** `protocolIsStoredOnlyWhenAdapterIsNotAlreadyAutomatic`, `unreadableProtocolSettingIsLeftAlone`.
- **BLE:** `BLEProbeGatingTests`.
- **Source scan:** `OutboundSurfaceInventoryTests` pins every outbound call site (session write, GATT writes, stream write, `EASession` creation, pump feed, transports/sessions/connectors). It checks every command-like literal outside comments against the gate. A new write path fails CI until it is reviewed.

## 6. Out of scope

- **Clearing DTCs** (service 04) will be a separate, explicitly confirmed feature in the diagnostics phase; it isn't reachable in Milestone 1. Implementing it will need a deliberate exception to the truncation rule, reviewed then.
- **Mazda service-22 reads** will only be added after each identifier is verified, and only as reads.
- **No `external-accessory` or Bluetooth background mode** in Milestone 1.
