# First hardware test (Milestone 1)

Goal: confirm Redline can reach the adapter, initialize it, decode RPM and measure the link, and capture the facts that are still unverified. About 15 minutes, parked, engine idling. No driving needed. The **OBDLink MX+** is the primary adapter; the Vgate iCar Pro 2S procedure is at the end.

Nothing in Redline sends anything that can change the car (see SAFETY.md). The only adapter setting it may change is the stored protocol, back to the factory "automatic", and only if it reads back as something else. The debug report says whether that happened.

## Before you go to the car

1. Open `Redline/Redline.xcodeproj` in Xcode, select the Redline target › Signing & Capabilities › choose your Team.
2. Run it on your iPhone once. Try **Connect › Start simulation**, then tap **Disconnect**.
3. **Quit the OBDLink app, WrenchTime and every other OBD app** (swipe them away). Only one app can use the adapter at a time.
4. For the background tests (step 8), launch Redline **from the home screen**, not from Xcode. The debugger keeps apps awake in the background and hides the real behaviour.

### Optional, at your desk: confirm the MX+'s protocol string first (Mac, ~5 min)

Redline can only see the MX+ if it declares the adapter's MFi protocol string. OBDLink doesn't publish it; Redline declares two community-sourced guesses (`com.obdlink`, `com.scantool.stnobd`). OBDLink's own iOS app must declare the real one in its Info.plist, so checking it there removes the biggest risk of the first test. These are general ways to read an app's Info.plist, not something verified with the OBDLink app; skip this if neither is convenient.

- **Mac with Apple silicon, if the OBDLink app installs from the Mac App Store** (iPhone apps sometimes do): install it, then in Terminal:
  `plutil -p /Applications/OBDLink.app/Wrapper/*.app/Info.plist | grep -A4 UISupportedExternalAccessoryProtocols`
- **Apple Configurator** (free, Mac App Store), with the OBDLink app installed on your iPhone and the iPhone connected:
  1. Choose Add › Apps › OBDLink. Configurator downloads the app and then asks whether to replace the installed copy.
  2. **Leave that dialog open.** The `.ipa` exists only while it's showing, under `~/Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Assets/TemporaryItems/MobileApps/` (Finder › Go › Go to Folder).
  3. Copy the `.ipa` out, then cancel the dialog.
  4. Rename the copy to `.zip`, unzip it, and look in `Payload/*.app/Info.plist` for the same key.

Send me the strings you find. If one isn't in Redline's list, it's a one-line change (`project.yml`) and a rebuild.

## OBDLink MX+

### Pair it (once)

1. Plug the MX+ into the OBD port and start the engine.
2. iPhone **Settings › Bluetooth** (Bluetooth on).
3. Press the **Connect** button on the MX+. The blue BT LED blinks fast; you have 2 minutes.
4. Tap **OBDLink MX+** under Other Devices. It should then show as **Connected**.
   - If it doesn't appear, wait up to a minute after plugging in, then press Connect again.
   - Holding the button for 15 s or more factory-resets the adapter; don't do that unless OBDLink support says to.

### Connect and capture

1. Redline › **Connect**. Under **OBDLink MX+ (Made for iPhone)**, the adapter should be listed with its manufacturer, model and firmware, and the status **"Ready — tap to connect"**. Write down exactly what you see.
   - **Nothing listed** although Settings shows it as Connected: neither of Redline's two candidate protocol strings matches the MX+. Still send the debug report (Debug tab): its **MFi accessories** section shows what iOS reports. Then see "If it doesn't work" below.
   - **"Waiting for iOS to finish authenticating…"**: wait 10 s and tap **Refresh**.
   - **"Not supported: offers …"**: send a screenshot. That line lists the MX+'s real protocol strings, which is exactly what's needed.
2. Tap it. The status should go: Connecting → Initializing adapter → Contacting vehicle → Detecting supported data → **Connected**. The MX+'s BT LED should turn solid.
3. **Live** tab: RPM about 700–800 at warm idle; blip the throttle and check RPM follows. Boost about −7.5 psi at idle; coolant about 190–200 °F when warm.
4. **Debug** tab › **Prepare debug report** › **Copy**, and paste it into our chat. ← **the main result.** It contains:
   - transport type
   - accessory name, manufacturer, model, serial, firmware, hardware and advertised protocols
   - the protocol string used, and an **MFi accessories** section: what Redline declares, every accessory iOS reports with its protocols, and the times the adapter connected and disconnected
   - each initialization command with its reply and timing
   - the connection-state history
   - round-trip times and the raw log
   - your iOS version
   - no location, and no VIN
5. Latency (~30 s each, report after each): Debug › Polling experiments.
   1. Polled set **RPM only** → wait 30 s → report.
   2. Toggle **Physical addressing** on → **Reconnect to apply** → 30 s → report.
6. **Unplug test:** unplug the MX+ for 10 s, then plug it back in. Expect Disconnected → Reconnecting, then recovery once iOS reconnects the adapter (this can take up to a minute). Report either way.
7. **Engine off, ignition on (optional):** expect "Vehicle unavailable" or RPM 0. Report what you see.
8. **Background test** (app launched from the home screen): while connected, go to the home screen for 15 s, then reopen Redline. Expected: it shows Connecting again and returns to Connected with a fresh session. Then send a debug report; the state history shows what happened.

### If it doesn't work

- **MX+ connected in Settings but not listed in Redline:** the protocol string is wrong. Redline can't see an accessory whose string it doesn't declare. Send the debug report and tell me. The fix is a one-line change in `project.yml` once the real string is known: see "confirm the MX+'s protocol string" above, or ask OBDLink support (they offer app developers a contact).
- **"iOS refused a session":** another app is holding the adapter. Quit it and tap Connect again.
- **Status stuck at Connecting:** check Settings shows the MX+ as Connected and the BT LED is blinking slowly or solid.
- **Initialization fails:** send the report anyway. The Initialization section shows which command failed and what the adapter said.

## Vgate iCar Pro 2S (Bluetooth LE)

1. Plug the Vgate in and start the engine. Don't pair it in iOS Settings; BLE adapters are found by scanning.
2. Redline › Connect › **Scan for Bluetooth LE adapters**. Note the name it shows up as. If it doesn't appear, turn on **Show all Bluetooth LE devices**.
3. Tap it, then follow steps 2–6 of "Connect and capture" above.
4. **"Unrecognized adapter Bluetooth layout — nothing was written"** is the safety gate working: no known ELM327 characteristic layout was found, so nothing was sent. The report's GATT table is what's needed to verify the layout.

## What I need back

- The debug reports (one per step above that asks for one).
- Screenshots of the Connect tab's MX+ section and the Live tab at idle.
- Anything that looked wrong or didn't happen, and your iOS version if the report didn't include it.
