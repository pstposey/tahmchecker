import XCTest

/// First-boot smoke test, run by CI on the iOS Simulator.
///
/// Covers what the first boot on a phone exercises without an adapter:
/// launching from a fresh install, the Connect screen (External Accessory and
/// Bluetooth LE sections), the simulator streaming through the real ELM327
/// parser and UI, the debug report, rotation, background/foreground and a
/// relaunch with saved settings. Screenshots are attached to the result
/// bundle; CI uploads them.
///
/// It proves nothing about the OBDLink MX+ or the car: the simulator has no
/// MFi accessories and no working Bluetooth.
final class FirstLaunchUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstLaunchSimulationAndLifecycle() {
        app = XCUIApplication()
        app.launch()
        expect(app.staticTexts["REDLINE"], "the Live tab's not-connected screen")
        expect(app.staticTexts["Not connected"], "the idle status")
        snapshot("01-first-launch")

        // Connect tab: both adapter sections render on a fresh install.
        tab("Connect")
        expect(app.staticTexts["No MFi accessory is connected to this iPhone."], "the MX+ section")
        snapshot("02-connect")

        // Bluetooth LE is unavailable on the Simulator; scanning must not crash.
        let allowBluetooth = addUIInterruptionMonitor(withDescription: "Bluetooth permission") { alert in
            for title in ["Allow", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        let scan = app.buttons["Scan for Bluetooth LE adapters"]
        scrollTo(scan)
        scan.tap()
        app.tap() // lets the interruption monitor handle a permission alert
        snapshot("03-ble-scan")
        removeUIInterruptionMonitor(allowBluetooth)
        if app.buttons["Stop scanning"].exists { app.buttons["Stop scanning"].tap() }

        // Simulation streams through the real parser, scheduler and UI.
        let start = app.buttons["Start simulation"]
        scrollTo(start)
        start.tap()
        tab("Live")
        expect(app.descendants(matching: .any)["Simulated data, not from a vehicle"], "the SIMULATION badge")
        expect(app.staticTexts["Connected"], "the streaming status", timeout: 30)
        expect(element(labelMatching: "RPM.*[0-9]"), "an RPM value", timeout: 30)
        expect(element(labelMatching: "BOOST.*[0-9]"), "a boost value", timeout: 30)
        snapshot("04-live-simulation")

        XCUIDevice.shared.orientation = .landscapeLeft
        expect(element(labelMatching: "RPM.*[0-9]"), "an RPM value in landscape")
        snapshot("05-live-landscape")
        XCUIDevice.shared.orientation = .portrait

        // Debug report.
        tab("Debug")
        app.buttons["Prepare debug report"].tap()
        expect(app.buttons["Copy"], "the Copy button")
        app.buttons["Copy"].tap()
        expect(app.buttons["Copied"], "the copy confirmation")
        snapshot("06-debug")

        // Background and foreground: the app keeps running and streaming.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningBackgroundSuspended, timeout: 5),
                      "Redline did not go to the background")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Redline did not return to the foreground")
        tab("Live")
        expect(app.staticTexts["Connected"], "streaming after returning to the foreground", timeout: 30)
        snapshot("07-after-background")

        // Disconnect.
        tab("Connect")
        let disconnect = app.buttons["Disconnect"]
        scrollTo(disconnect, up: true)
        disconnect.tap()
        tab("Live")
        expect(app.staticTexts["Not connected"], "the idle status after Disconnect", timeout: 15)
        snapshot("08-disconnected")

        // Relaunch with the settings this session saved.
        app.terminate()
        app.launch()
        expect(app.tabBars.buttons["Live"], "the tab bar after relaunch")
        snapshot("09-relaunch")
    }

    // MARK: Helpers

    @MainActor
    private func tab(_ name: String) {
        let button = app.tabBars.buttons[name]
        expect(button, "the \(name) tab")
        button.tap()
    }

    @MainActor
    private func element(labelMatching pattern: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@", ".*" + pattern + ".*")).firstMatch
    }

    @MainActor
    private func expect(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 10,
                        file: StaticString = #filePath, line: UInt = #line) {
        if !element.waitForExistence(timeout: timeout) {
            snapshot("failure-\(what)")
            XCTFail("Expected \(what) within \(Int(timeout)) s", file: file, line: line)
        }
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, up: Bool = false) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            up ? app.swipeDown() : app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "\(element) is not reachable")
    }

    @MainActor
    private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
