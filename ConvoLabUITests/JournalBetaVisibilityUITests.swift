import XCTest

final class JournalBetaVisibilityUITests: XCTestCase {
    @MainActor
    func testBetaMenuShowsOnlyJournalAndSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation", "-journal-beta-visibility"]
        app.launch()
        let picker = app.buttons["app-mode-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        XCTAssertTrue(picker.label.contains("Journal"))
        picker.tap()
        XCTAssertTrue(app.buttons["app-mode-journal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["app-mode-settings"].exists)
        for mode in ["study", "dailyAudio", "readings", "cards", "time"] {
            XCTAssertFalse(app.buttons["app-mode-\(mode)"].exists)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Journal-only beta menu"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["app-mode-settings"].tap()
        XCTAssertTrue(picker.label.contains("Settings"))
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
        for mode in ["dailyAudio", "journal", "readings", "cards", "time", "settings"] {
            XCTAssertTrue(app.buttons["app-mode-\(mode)"].exists)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Admin menu with all sections"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
