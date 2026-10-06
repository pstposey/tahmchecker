# Vgate iCar Pro 2S — Bluetooth LE interface

## What is known

| Item | Value | Status |
|---|---|---|
| Interface | ELM327-compatible command interpreter over BLE | VERIFIED indirectly (WrenchTime works with this adapter on this car) |
| Advertised name | — | **UNVERIFIED** |
| GATT service UUID | — | **UNVERIFIED** |
| Write characteristic | — | **UNVERIFIED** |
| Notify characteristic | — | **UNVERIFIED** |
| Write type (with / without response) | — | **UNVERIFIED** |
| Reported ELM version | — | **UNVERIFIED** (retail listings say "ELM 2.3"; clones may report any version) |
| MTU / max write length | — | **UNVERIFIED** |

No authoritative documentation was found for the GATT layout (searches turned up only retail listings). In line with the brief, **no UUID is hardcoded**.

## How Redline finds the link instead

`BLEOBDTransport.open`:

1. **Scan** without a service filter (`scanForPeripherals(withServices: nil)`). The list shows every named device with RSSI and its advertised services. Names containing obd/elm/vlink/vgate/icar get an "OBD?" tag and sort to the top. That's a **hint only**.
2. **Connect**, then **discover every service and characteristic**. The full GATT table is written to the debug log and the debug report.
3. **Rank candidate pairs** (`GATTCandidateRanker`): a writable characteristic plus a notify/indicate characteristic in the **same service**, skipping Bluetooth SIG standard services (1800, 1801, 180A, 180F, 1805). Write-without-response and notify rank higher. The commonly reported generic ELM layouts (`FFF0: FFF2→FFF1`, `FFE0: FFE1`, `18F0: 2AF1→2AF0`) only break ties; they're marked UNVERIFIED in code.
4. **Probe** up to 4 pairs, **but only pairs that match a recognized ELM327 bridge layout** (the list above, plus `E7810A71-…: BEF8D6C9-…`) or the pair previously verified on this adapter. For each: subscribe to notifications, write `ATI\r`, and wait 1.5 s for a `>`-terminated reply. The first pair that answers is **verified for this connection**. Probe traffic is shown in the raw log as `ATI (probe)`. Pairs that don't match are logged as "not probed" and receive **no writes at all**. If nothing matches, connection stops with *Unrecognized adapter Bluetooth layout — nothing was written* (see SAFETY.md).
5. **Remember** the verified pair (`AppSettings.verifiedLink`) and try it first next time. It's still re-verified by the ELM init (`ATZ` banner).

Probing writes a short, harmless ELM command (`ATI\r`). It's never written to a characteristic of unknown purpose, which on some adapters could be a configuration, name or firmware-update endpoint. That's why only recognized layouts are probed, standard services are skipped, at most 4 pairs are tried, and probing stops at the first success.

## After the first hardware session, fill in

From the debug report's **Link** section, record:

- Service UUID, write UUID and write type, notify UUID (the report marks them "VERIFIED by ELM probe")
- Max write lengths
- Full GATT table
- `ATZ` banner, `ATI`, `AT@1`

Then update the table above with the evidence (date, iOS version, adapter firmware if shown).

## Reconnection

- The adapter's `CBPeripheral.identifier` is stored (`rememberedAdapterID`). At launch, if auto-connect is on, Redline uses `retrievePeripherals(withIdentifiers:)` and connects without scanning.
- A CoreBluetooth `connect` request doesn't time out on its own. Redline adds a 12 s timeout and then retries with backoff (2 → 15 s) for as long as the engine runs.
- No `bluetooth-central` background mode in V1. iOS suspends the app in the background and Redline pauses polling. Whether to add background BLE (and state restoration) is an open question for the logging phase. Apple's rules need checking before that's claimed.

## Open questions for hardware

- Does the Vgate need an explicit write-with-response, or is write-without-response reliable?
- Notification chunk size: one notification per response, or 20-byte fragments?
- Does the adapter go to sleep when the ignition is off, and if so, how does it look? A BLE disconnect, or `LV RESET` / `ACT ALERT`?
