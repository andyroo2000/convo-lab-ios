import XCTest

@MainActor
final class JournalLearningUITests: XCTestCase {
    func testConfirmedPreferenceSurvivesRelaunchAndCanBeReset() {
        let app = launch(onboarding: true)
        app.buttons["JournalKeyboard-builtIn"].tap()
        app.buttons["JournalKeyboardConfirm"].tap()
        let field = app.textViews["Journal entry"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("ame")
        let strip = app.collectionViews["JournalCandidates"]
        XCTAssertTrue(strip.cells["雨"].waitForExistence(timeout: 120))
        app.buttons["JournalExpandCandidates"].tap()
        let candy = strip.cells["飴"]
        XCTAssertTrue(candy.waitForExistence(timeout: 15))
        candy.tap()
        XCTAssertEqual(field.value as? String, "飴")
        field.typeText("ame")
        let learned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "飴"), object: strip.cells.element(boundBy: 0))
        XCTAssertEqual(XCTWaiter.wait(for: [learned], timeout: 15), .completed)
        app.buttons["JournalExpandCandidates"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Learned conversion leads the full candidate panel"
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
        let reopened = launch(onboarding: false)
        let reopenedField = reopened.textViews["Journal entry"]
        reopenedField.tap()
        reopenedField.typeText("ame")
        let first = reopened.collectionViews["JournalCandidates"].cells.element(boundBy: 0)
        let persisted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "飴"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [persisted], timeout: 120), .completed)
        reopenedField.typeText("\n")
        reopened.buttons["Hide keyboard"].tap()
        reopened.buttons["app-account-menu"].tap()
        reopened.buttons["JournalKeyboard"].tap()
        let reset = reopened.buttons["JournalKeyboardResetLearning"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.tap()
        reopened.buttons["Reset"].tap()
        XCTAssertTrue(reopened.staticTexts["Learned conversions cleared."].waitForExistence(timeout: 10))
    }

    private func launch(onboarding: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation", onboarding ? "-journal-keyboard-onboarding" : "-journal-keyboard-keep"]
        app.launch()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 10))
        app.buttons["app-mode-picker"].tap()
        app.buttons["app-mode-journal"].tap()
        return app
    }
}
