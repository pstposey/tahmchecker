# OBDLink MX+ — how it reaches iOS

Status labels: **OFFICIAL** = OBDLink or Apple documentation (some OBDLink pages could only be read through search-engine snippets because their site blocked the research environment; marked *snippet*). **COMMUNITY** = independent developers' code or reports, not the manufacturer. **UNVERIFIED** = needs the physical adapter. Nothing in this file has been observed on Redline's hardware yet.

## The short version

The MX+ is **not** a Bluetooth LE device. It's a Bluetooth Classic (BR/EDR) adapter that iPhones reach through Apple's **MFi / External Accessory** framework. To an app, it's a pair of byte streams (`EASession.inputStream` / `outputStream`) carrying the same ELM327-style text protocol (commands ending in CR, replies ending in `>`). So Redline's ELM session, initializer, parser, scheduler and UI are reused unchanged. Only the transport differs.

| | Vgate iCar Pro 2S | OBDLink MX+ |
|---|---|---|
| Radio | Bluetooth LE | Bluetooth Classic v3.0 (OFFICIAL, snippet) |
| iOS API | CoreBluetooth (GATT write + notify) | External Accessory (`EAAccessoryManager`, `EASession` streams) (OFFICIAL) |
| Pairing | none; Redline scans and connects | iOS Settings › Bluetooth after pressing the adapter's Connect button (OFFICIAL, snippet) |
| Who connects | Redline (`CBCentralManager.connect`) | iOS; an app can only open a session to an accessory iOS already connected (OFFICIAL: Apple DTS) |
| Channel identity | GATT layout discovered and probed with `ATI` | MFi protocol string declared in Info.plist (UNVERIFIED string, see below) |
| Interpreter | ELM327 clone | OBD Solutions STN2255/STN2256, ELM327-compatible plus "ST" commands (OFFICIAL/COMMUNITY) |
| Redline transport | `BLEOBDTransport` (App) | `AccessoryStreamTransport` (core) + `EAStreamSession` (App) |

## Verified facts and their sources

- **Bluetooth Classic, not LE.**
  - OBDLink's MX+ spec says "Class 2 Bluetooth v3.0" with a physical Connect button (obdlink.com product page, snippet).
  - OBDLink says the CX "is the only device in the OBDLink product lineup to use Bluetooth Low Energy" (support article "OBDLink CX adapter notes", snippet).
  - One community README lists the MX+ under BLE. That contradicts the manufacturer, and Redline does not rely on it.
- **iOS access is MFi / External Accessory.**
  - Apple: the framework is for "MFi accessor[ies]… wirelessly with Bluetooth"; CoreBluetooth only reaches Classic devices via GATT over BR/EDR and exposes no RFCOMM/SPP.
  - Community iOS projects (LTSupportAutomotive, CornucopiaStreams, car-scanner developers) list the MX+ as an MFi accessory.
- **No app-initiated connect.**
  - `EAAccessoryManager` has no connect method. Apple DTS for MFi OBD adapters: "Manually pair/connect to your accessory through Bluetooth settings. Launch your app and check connectedAccessories."
- **Pairing procedure** (OBDLink iOS quick-start guide, snippet):
  1. Plug in.
  2. In iOS Settings › Bluetooth, press the MX+'s Connect button (BT LED blinks fast).
  3. Tap "OBDLink MX+" within 2 minutes.
  - It may take 45–60 s to show up after first plugging in (OBDLink support, snippet).
  - LEDs: BT blinks fast when ready to pair, slowly when ready for a paired device, and is solid when connected.
- **One app at a time.**
  - "The OBDLink adapter can only connect to one app at a time" (OBDLink support, snippet).
  - Apple: only one session per accessory and protocol.
- **Background.**
  - Without the `external-accessory` background mode, the app gets a disconnect for each accessory when it goes to the background (Apple EADemo README; iOS 5-era text, not re-documented since).
  - Accessory notifications are queued and coalesced while the app is suspended (Apple, External Accessory Programming Topics).
- **Distribution.**
  - Declaring an accessory's protocol "will work in a development version of the app". App Review rejects it unless the accessory maker approved the bundle ID (Apple DTS).
  - Xcode-installed builds should therefore work without OBDLink's involvement (**UNVERIFIED** on this adapter). App Store or TestFlight would need OBDLink to whitelist `com.pstposey.Redline`.
- **Firmware updates** are done by the OBDLink app or the Windows utility, never by third-party apps (OBDLink support, snippet). Redline never sends ST or bootloader commands; the read-only policy refuses every `ST…` command.

## The protocol string (UNVERIFIED)

Neither OBDLink nor Apple publishes the MX+'s External Accessory protocol string. iOS hides any accessory whose protocol the app doesn't declare, and the match is case-sensitive. Redline declares two community-sourced candidates in `project.yml` / Info.plist:

| String | Evidence |
|---|---|
| `com.obdlink` | Used for OBDLink MFi adapters by two independent open-source projects (CornucopiaStreams: `ea://com.obdlink`; a get-ride Info.plist for "OBDLink MX+ and similar"). Neither shows a hardware log. |
| `com.scantool.stnobd` | Attributed by one Swift library to the OBDLink EX (USB). Unknown whether the MX+ uses it. |

What happens on the first test:

- **One of the strings is correct:** the MX+ appears in Redline's Connect list. Its full metadata and every protocol it advertises go into the debug report.
- **Neither is correct:** the MX+ won't appear in Redline at all, even though iOS Settings shows it as connected. Redline cannot read an undeclared accessory's protocol list. The fix is to learn the real string and add it to `project.yml`. Two ways to learn it:
  - OBDLink's own iOS app must declare it in its Info.plist; HARDWARE_TEST.md describes how to read that from a Mac.
  - OBDLink offers app developers a listing/whitelisting contact.

The debug report's **MFi accessories** section always shows what Redline declares, every accessory iOS reports (with its protocols and whether it's supported), and recent connect/disconnect notifications. Redline starts watching for accessories at launch, so these events are also in the raw log.

## How Redline talks to it

- **`ExternalAccessoryCenter` (App, `@MainActor`)**
  - Created lazily from the Connect screen or when connecting. Apple advises against touching EA during app initialization.
  - Registers for accessory notifications once and keeps the connected list as Sendable `AccessoryDescriptor` snapshots.
  - Opens an `EASession` only for an accessory that advertises a declared protocol. An accessory reporting no protocols yet is still being authenticated by iOS, so it waits.
  - Never sets `EAAccessory.delegate`. It's `unowned(unsafe)` and has been linked to crashes; notifications are used instead.
- **`EAStreamSession` (App)**
  - Owns one dedicated thread running its own run loop. Both streams are scheduled there and only touched there.
  - Teardown mirrors setup: close, unschedule, drop the delegate, release the session.
  - Apple DTS advises against GCD queues or Swift-concurrency executors for these streams.
- **`StreamPump` (core)**
  - Follows Apple DTS's non-blocking pattern: read once per has-bytes event; write only after a has-space event, tracking space itself rather than trusting `hasSpaceAvailable`.
  - Handles partial writes and turns stream errors or end-of-stream into one close.
- **`AccessoryStreamTransport` (core, `OBDTransport`)**
  - Waits up to 30 s for the accessory (the engine retries after that), then up to 5 s for both streams to open.
  - Handles cancellation, an orderly close, and disconnects from stream errors or `EAAccessoryDidDisconnect`.
  - Unit-tested with mock streams that force 3-byte partial writes and flow-control stalls. The real engine runs on top of it end to end.
- **App lifecycle:** going to the background closes the MFi session cleanly. Returning re-reads the accessory list and opens a fresh session. A session is never reused across suspension.
- **Recovery:** a session that opens but never delivers bytes (reported on iOS 27 for USB accessories) ends as an `ATZ` timeout. The engine reconnects with a fresh `EASession`.

Read-only: the MX+ path adds no command source. Every byte written comes from `ELM327Session` after the policy gate. See SAFETY.md.

## Risks to watch on hardware

- **SwiftUI.** Apple DTS has reported "integration issues with the External Accessory framework and our modern APIs, even on iOS 18" and "longstanding issues with the ExternalAccessory framework and SwiftUI", without saying which. Redline is a SwiftUI app; EA code is kept in plain main-actor classes, not views. Test on the iOS version you actually run.
- **iOS 27.** There are reports of `EASession` returning nil, or opening with an input stream that never delivers data. Both involved USB accessories. Redline recovers through timeouts and a fresh session; the debug report includes the iOS version.
- **Xcode debugger.** Running under the debugger keeps the app alive in the background, so background and foreground tests are only meaningful when the app is launched from the home screen.
- **The in-app Bluetooth accessory picker** (`showBluetoothAccessoryPicker`) is reported broken in SwiftUI/scene apps (FB9856371), so Redline doesn't use it. Pairing is done in Settings.
- **Sleep.** The MX+ has its own automatic sleep (BatterySaver™, 2 mA). When it sleeps the Bluetooth link drops, which Redline handles as a normal disconnect and reconnect. Its sleep and wake triggers and timing are UNVERIFIED.
- **Performance.**
  - OBDLink markets up to 100 samples/s on iOS. A community report suggests MFi throughput on iOS is far lower than on Android.
  - Neither is measured for Redline. Polling stays adaptive; numbers go into DEVLOG.md once measured.

## STN interpreter: what's unverified for Redline's commands

The STN-chip research angle did not complete (usage limit), and the STN programming manual couldn't be fetched. Treat all of this as **UNVERIFIED** until the first debug report:

- **`ATZ`:** the reset banner text and duration.
- **`ATI` / `AT@1`:** the exact reply text.
- **`ATSP0`:** whether STN stores the protocol in non-volatile memory the way ELM327 does. Redline still sends it only when `ATDPN` reads back a non-automatic setting, and reports it if it does.
- **Response format:** `ATH1`/`ATS1` headers, response timing, adaptive timing, and how `STOPPED` and the prompt behave on interruption.
- **Response-count hint:** irrelevant; it is disabled by the read-only policy.
