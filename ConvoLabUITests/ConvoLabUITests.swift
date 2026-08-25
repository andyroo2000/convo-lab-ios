import XCTest

final class ConvoLabUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testFixtureRendersProductionLoginView() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "login-screen"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Study without\nbreaking your flow."].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.textFields["Email"].exists)
        XCTAssertTrue(app.secureTextFields["Password"].exists)
        XCTAssertTrue(app.buttons["Sign In"].exists)
        XCTAssertFalse(app.buttons["Sign In"].isEnabled)
    }
}
