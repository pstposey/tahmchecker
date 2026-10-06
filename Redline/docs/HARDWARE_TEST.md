# First hardware test (Milestone 1)

Goal: confirm the adapter can be discovered and verified, ELM init succeeds, RPM decodes, and the communication path can be measured. About 10 minutes, parked, engine idling. No driving needed.

## Before you go to the car

1. Open `Redline/Redline.xcodeproj` in Xcode, select the Redline target › Signing & Capabilities › choose your Team.
2. Run it on your iPhone once and allow Bluetooth when asked. Try **Connect › Start simulation** to see the app working, then tap **Disconnect**.
3. **Quit WrenchTime** (swipe it away). Two apps can't share the adapter's ELM interpreter.

## In the car

1. Plug the Vgate iCar Pro 2S into the OBD port. Start the engine and let it idle.
2. Redline › **Connect** › **Scan for adapters**.
   - Note the name the Vgate shows up as. If it doesn't appear, turn on **Show all Bluetooth devices**.
3. Tap the Vgate.
   - The status should go: Connecting → Initializing adapter → Contacting vehicle → Detecting supported data → **Connected**.
4. **Live** tab: RPM should read about 700–800 at warm idle. Blip the throttle and check that RPM follows.
   - Boost should read about −7.5 PSI at idle. Coolant should be roughly 190–200 °F when warm.
5. **Debug** tab › **Prepare debug report** › **Copy**, then paste the report into our chat. ← **the main result**
6. Latency experiments (~30 s each, report after each). Polling experiments section:
   1. Polled set **RPM only** → wait 30 s → report.
   2. Toggle **Response-count hint** on → **Reconnect to apply** → 30 s → report.
   3. Toggle **Physical addressing** on as well → **Reconnect** → 30 s → report.
7. Disconnect test: unplug the adapter for 10 s, then plug it back in. The app should show Disconnected → Reconnecting, then recover on its own. Report either way.
8. Optional: engine off, ignition on. Expect "Vehicle unavailable" or RPM 0. Report what you see.

## What I need back

- The debug reports (they include the GATT table, ELM version, protocol, supported PIDs, round-trip times and the raw log; no location data, no VIN).
- A screenshot of the Live tab at idle.
- Anything that looked wrong or didn't happen.

If the adapter doesn't connect, the report's raw log shows which step failed (scan, connect, GATT discovery, probe, ATZ…). Send it even then.
