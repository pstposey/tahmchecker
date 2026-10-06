# OBD-II and ELM327

Status labels: **VERIFIED** = confirmed against hardware or an authoritative source and tested. **CROSS-CHECKED** = consistent across independent secondary sources, but not yet observed on this adapter or vehicle. **UNVERIFIED** = assumption, needs hardware.

## Sources used

- ELM327 datasheet (Elm Electronics). The official site couldn't be reached from the development environment, so its contents were taken from implementations that follow it:
  - Linux kernel `can327` driver documentation (`Documentation/networking/device_drivers/can/can327.rst`): prompt, `?`, 11-bit vs 29-bit header display, BUFFER FULL, clone caveats.
  - python-OBD (`obd/elm327.py`, `obd/protocols/protocol_can.py`, `obd/decoders.py`, `obd/UnitsAndScaling.py`): init sequence, protocol numbering, CAN frame layout with headers, SAE J1979 unit/scaling IDs.
- SAE J1979 service 01 PID scalings, cross-checked against python-OBD's unit-and-scaling table.

**TODO:** re-check the items below against the primary ELM327 datasheet when available, specifically the interrupt behaviour (what happens to the rest of a line whose first character interrupted a busy adapter), and the default timeout and adaptive-timing values. The OBDLink MX+ uses an STN interpreter (ELM327-compatible plus "ST" commands); its replies to the commands below are UNVERIFIED until the first debug report (MXPLUS.md).

## Initialization sequence

Defined in `ELMInitializer.adapterSteps`. Every command has a reason:

| Command | Expect | Why | Status |
|---|---|---|---|
| `ATZ` | banner | Full reset to known defaults; prints the version the adapter **claims**. Clones may claim any version (can327 docs) | CROSS-CHECKED |
| `ATE0` | OK | Echo off: fewer bytes, simpler parsing. The parser also strips an echo if present | CROSS-CHECKED |
| `ATL0` | OK | Lines end with CR only | CROSS-CHECKED |
| `ATS1` | OK | Spaces on. With headers on, the spaces keep the 11-bit (`7E8`) and 29-bit (`18 DA F1 10`) formats unambiguous (can327 docs give the same reasoning). Dropping spaces saves ~6 bytes per response; that's a measured experiment for Phase 7, not an assumption | CROSS-CHECKED |
| `ATH1` | OK | Headers on: identify which ECU answered. On CAN, several ECUs can answer a functional request (7DF) | CROSS-CHECKED |
| `ATI`, `AT@1`, `ATRV` | any | Identification, device description, supply voltage. Informational, failures tolerated | — |
| `ATDPN` | `0`/`A6`/… | Reads the adapter's current protocol setting | CROSS-CHECKED |
| `ATSP0` | OK | **Only if** `ATDPN` reads back a setting that isn't automatic (never if `ATDPN` is unreadable). `AT SP` also **stores** the protocol in the adapter (its one persistent setting change; it restores the factory default "automatic"), so Redline avoids it when unnecessary and reports it in the debug report | CROSS-CHECKED |
| `0100` | data | First OBD request; triggers protocol search (`SEARCHING...`, up to ~12 s timeout). Gives the ECU list and the PIDs 01–20 bitmask | CROSS-CHECKED |
| `ATDPN`, `ATDP` | `A6` etc. | Which protocol was found. `A` prefix = found automatically | CROSS-CHECKED |
| `0120`, `0140`, … | data | Remaining support ranges, only while an ECU advertises the next range | CROSS-CHECKED |

Expected for the CX-30 (**UNVERIFIED**): ISO 15765-4 CAN 11-bit 500 kbaud (`ATDPN` → `A6`), engine ECU at `7E8`. The Debug tab and the debug report show what was actually found.

Not sent, on purpose: `ATAT` (adaptive timing; the default is assumed to be on, UNVERIFIED), `ATST` (timeout), `ATCAF` (CAN auto-formatting; the default is on). These are tuning knobs for Phase 7 and will only be changed with measurements.

## Response handling

- **Framing:** a response is everything before the `>` prompt (`ELMResponseFramer`). BLE notifications may split it anywhere. NUL bytes are dropped. Memory is bounded.
- **Classification** (`ELMResponse.classify`): `OK`, `?`, `SEARCHING...` (removed), `BUS INIT: ...OK` (removed), and these messages: NO DATA, UNABLE TO CONNECT, CAN ERROR, BUS BUSY, BUS ERROR, BUS INIT ERROR, BUFFER FULL, DATA ERROR / `<DATA ERROR`, `<RX ERROR`, FB ERROR, LV RESET, STOPPED, ACT ALERT, LP ALERT, ERRnn, ERROR. Echo of the command is removed.
- **Frames** (`OBDFrameParser`):
  - Headers on, CAN 11-bit: `7E8 04 41 0C 1A F8` → ID, ISO-TP PCI byte, data. Bytes beyond the PCI length are padding and ignored.
  - ISO-TP first frame (`1x LL`) and consecutive frames (`2n`) are reassembled per ECU, with sequence checking. A gap drops the message and records an issue.
  - CAN 29-bit: `18 DA F1 10 …` (4 header bytes).
  - Legacy protocols (J1850/ISO 9141/KWP): 3 header bytes, data, checksum. **UNTESTED on hardware.**
  - Headers off: data lines, or `014` / `0:` / `1:` indexed multi-line messages.
  - Malformed input becomes an *issue* string that gets logged. It never crashes and never gets decoded.
- **Matching** (`OBDResponseDecoder`): the payload must start with `[service + 0x40, PID]` and contain at least the definition's byte count, otherwise the response is malformed. `7F sid nrc` is a negative response. If several ECUs answer, the one listed first in the support map wins (`7E8` first), then the lowest address.
- **Plausibility:** decode-sanity bounds only, such as RPM ≤ 12,000 and BARO 45–110 kPa. These are not mechanical limits. Out-of-range values are marked invalid, logged with raw bytes and never displayed; they are not clamped.

## Session robustness (`ELM327Session`)

- One command in flight at a time (FIFO gate). The poller and the console share it safely.
- **Timeout:** the session marks itself out of sync. Before the next command it waits 400 ms for the late prompt and *discards* that response, and waits longer while a late response is visibly still arriving.
- **Unknown state:** if no prompt arrives, the adapter may still be busy, or its prompt was lost. A command written now could reach a busy adapter, which discards the interrupting character and might act on the rest of the line. So the session sends the probe `ATI`, whose truncations (`TI`, `I`) are not commands, until it gets a clean identification reply followed by 400 ms of silence. Only then does the real command go out. After 4 unclear probes → adapter unresponsive → reconnect from `ATZ`.
- **No bare CR:** a bare CR is never sent, because an idle ELM327 repeats its last command on one.
- **Cancellation and failed writes** also mark the session out of sync. The adapter will still answer an abandoned command, and part of a failed line may sit in its buffer.
- **Vehicle silent** (`0100` unanswered): retried after 3 s for the first five attempts, then every 10 s, then every 30 s, to limit protocol-search traffic with the ignition off. Returning to the foreground retries immediately.

## Standard PIDs used

All service 01. Formulas are in `StandardPIDs.swift` and tested in `PIDDecodingTests`. Base units: kPa, °C, km/h, rpm, %, V, °, s, λ, g/s, L/h.

| PID | Channel | Formula | Class |
|---|---|---|---|
| 04 | Engine load: **never requested** (`0104` is refused by the truncation rule, see SAFETY.md §4; use 43) | A·100/255 % | fast |
| 05 | Coolant | A − 40 °C | slow |
| 06/07 | STFT/LTFT B1 | A·100/128 − 100 % | medium |
| 0A | Fuel pressure (gauge) | 3A kPa | medium |
| 0B | MAP (absolute) | A kPa | fast |
| 0C | RPM | (256A+B)/4 | fast |
| 0D | Speed | A km/h | medium |
| 0E | Timing advance | A/2 − 64 ° | medium |
| 0F | IAT | A − 40 °C | medium |
| 10 | MAF | (256A+B)/100 g/s | medium |
| 11 | Throttle | A·100/255 % | fast |
| 1F | Run time | 256A+B s | slow |
| 22 | Fuel rail (rel. vacuum) | 0.079(256A+B) kPa | medium |
| 23 | Fuel rail gauge | 10(256A+B) kPa | medium |
| 24 / 34 | O2 S1 wide-range λ | 2/65536·(256A+B) | medium |
| 2F | Fuel level | A·100/255 % | slow |
| 33 | BARO | A kPa | slow |
| 42 | Module voltage | (256A+B)/1000 V | slow |
| 43 | Absolute load | (256A+B)·100/255 % | medium |
| 44 | Commanded λ | 2/65536·(256A+B) | medium |
| 45, 47, 4A, 4C, 5A | Throttle/pedal variants | A·100/255 % | medium |
| 46 | Ambient | A − 40 °C | slow |
| 49 | Accelerator pedal D | A·100/255 % | fast |
| 59 | Fuel rail absolute | 10(256A+B) kPa | medium |
| 5C | Oil temp (only if supported) | A − 40 °C | slow |
| 5E | Fuel rate | (256A+B)/20 L/h | medium |

Which of these the CX-30 supports is **UNVERIFIED** until the first hardware session. Discovery decides; nothing is assumed.

## Boost (calculated)

`boost_kPa = MAP_kPa − BARO_kPa` (`BoostCalculator`, `TelemetryStore.deriveBoost`).

- Computed once per valid MAP sample, using the most recent valid BARO. BARO is cached because ambient pressure changes slowly. The boost sample inherits the MAP sample's timestamps and records its inputs, e.g. "MAP 31 kPa − BARO 83 kPa (BARO age 1.2 s)".
- **No sea-level fallback.** If BARO is unsupported, boost shows "Requires BARO (PID 33)…". If BARO is supported but hasn't arrived yet, boost shows `--`.
- Peak boost counts only positive values.
- Limits: PID 0B has 1 kPa resolution (≈0.15 psi) and a 255 kPa absolute ceiling, so boost can't read above 255 − BARO (≈172 kPa ≈ 25 psi at 83 kPa BARO). The CX-30's observed +115 kPa peak is within that range.
- A possible future fallback, not implemented: capture MAP at key-on/engine-off as an *estimated* BARO, labelled ESTIMATED.

Field references (sanity checks only, from WrenchTime on this car): idle ≈ −52 kPa (−7.54 psi), MAP ≈ 31 kPa, so BARO ≈ 83 kPa; peaks +84, +90, +115 kPa (12.18, 13.05, 16.68 psi). Unit tests assert these conversions.

## Read-only policy

See **[SAFETY.md](SAFETY.md)** for the complete outbound inventory. In short, `CommandSafetyPolicy` is enforced inside `ELM327Session.execute` for every caller:

- **OBD requests:** only SAE J1979 read services 01, 02, 03, 06, 07, 09 and 0A, at most 7 bytes. Everything else is refused, including 04 (clear DTCs; this will get its own confirmation flow later), 08 (actuator control) and every UDS/KWP service (22 included until Mazda identifiers are verified). Lines whose truncation would be a clear or a non-read request with parameters are refused too (`0104`, `010C1`, multi-PID requests).
- **AT commands:** a fixed allowlist (initialization, informational queries, `ATSH7E0`–`7E7`). The console allows only the informational subset (I, @1, RV, DP, DPN, CS, IGN).

## Mazda-enhanced PIDs

None are implemented, and none will be added without verified mode, header, address, response format, formula and units, with the evidence documented here.
