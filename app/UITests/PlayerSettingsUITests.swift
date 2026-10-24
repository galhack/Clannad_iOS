import XCTest

final class PlayerSettingsUITests: XCTestCase {
    func testControlButtonSwitchCanBeEnabledAndPersistsAcrossLaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["CLANNAD_AUTOSTART"] = "0"
        app.launch()
        var toggle = controlSwitch(in: app)
        if toggle.value as? String == "0" { toggle.tap() }
        XCTAssertEqual(toggle.value as? String, "1")

        app.terminate()
        app.launch()
        toggle = controlSwitch(in: app)
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        app.terminate()
    }

    private func controlSwitch(in app: XCUIApplication) -> XCUIElement {
        let toggle = app.switches["launcher.showControlButtons"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        for _ in 0..<3 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        return toggle
    }
}
