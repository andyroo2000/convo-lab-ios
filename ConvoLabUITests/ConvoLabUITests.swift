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

    @MainActor
    func testRestoresLoginIntoProductionRootViewAcrossRelaunch() {
        let app = launchFixture("login-restoration", reset: true)
        XCTAssertTrue(app.tabBars.buttons["Study"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)

        app.terminate()
        launchFixture("login-restoration", reset: false, application: app)
        XCTAssertTrue(app.tabBars.buttons["Study"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testOfflineReviewRemainsQueuedAcrossRelaunch() {
        let app = launchFixture("offline-review", reset: true)
        XCTAssertTrue(app.textViews["復習する"].waitForExistence(timeout: 8))
        app.buttons["Show Answer"].tap()
        XCTAssertTrue(app.buttons["Good"].waitForExistence(timeout: 3))
        app.buttons["Good"].tap()
        XCTAssertTrue(app.staticTexts["Nice work"].waitForExistence(timeout: 8))
        let pendingCount = app.staticTexts["pending-offline-review-count"]
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(
                        format: "label == %@",
                        "Pending offline reviews: 1"
                    ),
                    object: pendingCount
                )],
                timeout: 8
            ),
            .completed
        )

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 3))
        app.terminate()
        launchFixture("offline-review", reset: false, application: app)
        XCTAssertTrue(pendingCount.waitForExistence(timeout: 8))
        XCTAssertEqual(pendingCount.label, "Pending offline reviews: 1")
    }

    @MainActor
    func testCreateCardDraftRecoversAcrossRelaunch() {
        let app = launchFixture("create-card-recovery", reset: true)
        let answer = app.textFields["Japanese answer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        answer.tap()
        answer.typeText("忘れない")
        let meaning = app.textFields["Meaning (optional)"]
        meaning.tap()
        meaning.typeText("not to forget")
        let prepare = app.buttons["Prepare"]
        XCTAssertTrue(prepare.isEnabled)
        prepare.tap()
        app.swipeUp()
        XCTAssertTrue(
            app.staticTexts["card-editor-error"]
                .waitForExistence(timeout: 8)
        )

        app.terminate()
        launchFixture("create-card-recovery", reset: false, application: app)
        XCTAssertTrue(app.navigationBars["Review Draft"].waitForExistence(timeout: 8))
        for _ in 0..<3 {
            app.swipeDown()
        }
        let recoveredAnswer = app.textFields
            .matching(NSPredicate(format: "value == %@", "忘れない"))
            .firstMatch
        XCTAssertTrue(recoveredAnswer.waitForExistence(timeout: 8))
        XCTAssertEqual(recoveredAnswer.value as? String, "忘れない")
    }

    @MainActor
    func testDailyAudioPlaybackUsesProductionControls() {
        let app = launchFixture("daily-audio-playback", reset: true)
        XCTAssertTrue(
            app.staticTexts["Deterministic Daily Audio"].waitForExistence(timeout: 8)
        )
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 8))
        play.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testGoogleCalendarConnectsThroughProductionSettingsFlow() {
        let app = launchFixture("calendar-connection", reset: true)
        let connect = app.buttons["Connect Google Calendar"]
        for _ in 0..<3 where !connect.exists {
            app.swipeUp()
        }
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        connect.tap()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(
                    format: "label CONTAINS %@",
                    "calendar@ui-tests.invalid"
                ))
                .firstMatch.exists
        )
        XCTAssertTrue(app.buttons["Calendar Settings"].exists)
    }

    @MainActor
    @discardableResult
    private func launchFixture(
        _ fixture: String,
        reset: Bool,
        application: XCUIApplication = XCUIApplication()
    ) -> XCUIApplication {
        application.launchArguments = ["-ui-test-fixture", fixture]
        application.launchEnvironment["UI_TEST_RESET"] = reset ? "1" : "0"
        application.launch()
        return application
    }
}
