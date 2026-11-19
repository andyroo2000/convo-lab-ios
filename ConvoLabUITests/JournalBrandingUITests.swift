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
        app.swipeUp()
        XCTAssertTrue(app.buttons["auth-register-submit"].exists)
        XCTAssertFalse(app.buttons["auth-register-submit"].isEnabled)
        app.buttons["Cancel"].tap()
        app.buttons["Forgot password?"].tap()
        XCTAssertTrue(app.buttons["Send reset link"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Send reset link"].isEnabled)
        capture(app, name: "journal-password-reset")
    }

    @MainActor
    func testRegistrationExplainsMismatchedPasswords() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "login-screen"]
        app.launch()
        app.buttons["Create an account"].tap()
        let password = app.secureTextFields["auth-register-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        app.swipeUp()
        password.tap()
        if app.buttons["GenerateStrongPasswordButton"].waitForExistence(timeout: 3) {
            app.buttons["Close"].tap()
        }
        password.typeText("example-password")
        let confirmation = app.secureTextFields["Confirm password"]
        confirmation.tap()
        if app.buttons["GenerateStrongPasswordButton"].waitForExistence(timeout: 3) {
            app.buttons["Close"].tap()
        }
        confirmation.typeText("different-password")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Passwords do not match."].exists)
        XCTAssertFalse(app.buttons["auth-register-submit"].isEnabled)
    }

    @MainActor
    func testSignInFitsAccessibilityTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "login-screen",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        app.swipeUp()
        XCTAssertTrue(app.textFields["Email"].exists)
        XCTAssertTrue(app.secureTextFields["Password"].exists)
        XCTAssertGreaterThanOrEqual(app.textFields["Email"].frame.minX, app.frame.minX + 24)
        XCTAssertLessThanOrEqual(app.textFields["Email"].frame.maxX, app.frame.maxX - 24)
        capture(app, name: "journal-login-accessibility")
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
    func testHeaderFitsAccessibilityTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let picker = app.buttons["app-mode-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.isHittable)
        XCTAssertLessThanOrEqual(picker.frame.maxX, app.frame.maxX)
        capture(app, name: "journal-header-accessibility")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
