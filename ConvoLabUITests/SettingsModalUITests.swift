import XCTest

final class SettingsModalUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testAccordionAndProfileReturnToJournalWithoutLosingDraft() {
        let app = launch(beta: true)
        let entry = app.textViews["Journal entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        entry.typeText("Keep this draft while editing settings.")
        openSettings(app)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Sign Out")).count, 1)
        XCTAssertFalse(app.buttons["Done"].exists)
        app.buttons["Edit Profile"].tap()
        let closeProfile = app.buttons["SettingsClose-Edit profile"]
        XCTAssertTrue(closeProfile.waitForExistence(timeout: 5))
        let name = app.textFields["Name"]
        let email = app.textFields["Email"]
        let save = app.buttons["SettingsSaveProfile"]
        XCTAssertTrue(name.exists)
        XCTAssertTrue(email.exists)
        XCTAssertTrue(save.isHittable)
        XCTAssertGreaterThan(save.frame.minY, email.frame.maxY + 16)
        capture(app, name: "Journal profile fields")
        closeProfile.tap()
        XCTAssertTrue(app.buttons["SettingsClose-Settings"].waitForExistence(timeout: 5))
        capture(app, name: "Journal accordion settings")
        app.buttons["SettingsClose-Settings"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertEqual(entry.value as? String, "Keep this draft while editing settings.")
        XCTAssertTrue(app.buttons["app-mode-picker"].label.contains("Journal"))
    }

    @MainActor
    func testCalendarIsHiddenWithoutStudyAccess() {
        let app = launch(beta: true)
        openSettings(app)
        app.buttons["SettingsChapter-Connections"].tap()
        XCTAssertTrue(app.buttons["SatoriReaderIntegrationLink"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Google Calendar"].exists)
        XCTAssertFalse(app.buttons["Connect Google Calendar"].exists)
        XCTAssertFalse(app.buttons["Edit Profile"].exists)
        app.buttons["SettingsChapter-Account"].tap()
        XCTAssertTrue(app.buttons["Edit Profile"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["SatoriReaderIntegrationLink"].exists)
    }

    @MainActor
    func testCalendarIsAvailableWithStudyAccess() {
        let app = launch(beta: false)
        openSettings(app)
        app.buttons["SettingsChapter-Connections"].tap()
        let calendar = app.buttons["Google Calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        calendar.tap()
        XCTAssertTrue(app.buttons["Connect Google Calendar"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func launch(beta: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation"]
        if beta { app.launchArguments.append("-journal-beta-visibility") }
        app.launch()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        app.buttons["app-mode-picker"].tap()
        app.buttons["app-mode-settings"].tap()
        XCTAssertTrue(app.buttons["SettingsClose-Settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
