import XCTest

final class JournalBrandingUITests: XCTestCase {
    @MainActor
    func testAuthenticationScreensKeepNativeFieldsAndJournalBrand() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "login-screen"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["ConvoLab Journal"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Sign in"].isEnabled)
        capture(app, name: "journal-login")

        app.buttons["Create an account"].tap()
        XCTAssertTrue(app.textFields["Invite code"].waitForExistence(timeout: 5))
        capture(app, name: "journal-registration")
        app.buttons["Cancel"].tap()
        app.buttons["Forgot password?"].tap()
        XCTAssertTrue(app.buttons["Send reset link"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Send reset link"].isEnabled)
        capture(app, name: "journal-password-reset")
    }

    @MainActor
    func testHeaderKeepsNativeModeNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation"]
        app.launch()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 5))
        app.buttons["app-mode-picker"].tap()
        app.buttons["Journal"].tap()
        XCTAssertTrue(app.buttons["app-mode-picker"].label.contains("Journal"))
        capture(app, name: "journal-header")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
