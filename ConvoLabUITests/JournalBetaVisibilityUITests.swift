import XCTest

final class JournalBetaVisibilityUITests: XCTestCase {
    @MainActor
    func testJournalOnlyHasNoDropdownAndSettingsLivesInAccountMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation", "-journal-beta-visibility"]
        app.launch()
        let picker = app.buttons["app-mode-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        XCTAssertTrue(picker.label.contains("Journal"))
        XCTAssertFalse(picker.isEnabled)
        XCTAssertFalse(app.buttons["app-mode-journal"].exists)
        XCTAssertFalse(app.buttons["app-mode-dailyAudio"].exists)
        XCTAssertFalse(app.buttons["app-mode-settings"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Journal-only beta menu"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["app-account-menu"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["SettingsClose-Settings"].waitForExistence(timeout: 5))
        app.buttons["SettingsClose-Settings"].tap()
        XCTAssertTrue(picker.label.contains("Journal"))
    }

    @MainActor
    func testEnabledSectionsRemainAvailableToAdmins() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation"]
        app.launch()
        let picker = app.buttons["app-mode-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        picker.tap()
        XCTAssertTrue(app.buttons["app-mode-study"].waitForExistence(timeout: 5))
        for mode in ["journal", "readings", "cards", "time"] {
            XCTAssertTrue(app.buttons["app-mode-\(mode)"].exists)
        }
        XCTAssertFalse(app.buttons["app-mode-dailyAudio"].exists)
        XCTAssertFalse(app.buttons["app-mode-settings"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Admin menu with all sections"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
