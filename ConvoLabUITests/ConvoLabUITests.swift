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
        let leftForeground = app.wait(for: .runningBackground, timeout: 3)
            || app.state == .runningBackgroundSuspended
        XCTAssertTrue(leftForeground)
        app.terminate()
        launchFixture("offline-review", reset: false, application: app)
        XCTAssertTrue(pendingCount.waitForExistence(timeout: 8))
        XCTAssertEqual(pendingCount.label, "Pending offline reviews: 1")
    }

    @MainActor
    func testCreateCardDraftRecoversAcrossRelaunch() {
        let app = launchFixture("create-card-recovery", reset: true)
        let create = app.buttons["Create Card"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        let cardType = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Text recognition")
        ).firstMatch
        XCTAssertTrue(cardType.waitForExistence(timeout: 5))
        cardType.tap()
        let audioRecognition = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Audio recognition")
        ).firstMatch
        XCTAssertTrue(waitForHittable(audioRecognition, timeout: 20))
        audioRecognition.tap()
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
        let recovery = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Resume audio recognition draft")
        ).firstMatch
        XCTAssertTrue(recovery.waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Resume audio recognition draft")
        ).count, 1)
        recovery.tap()
        XCTAssertTrue(app.navigationBars["Resume Draft"].waitForExistence(timeout: 8))
        for _ in 0..<3 {
            app.swipeDown()
        }
        let recoveredAnswer = app.textFields
            .matching(NSPredicate(format: "value == %@", "忘れない"))
            .firstMatch
        XCTAssertTrue(recoveredAnswer.waitForExistence(timeout: 8))
        XCTAssertEqual(recoveredAnswer.value as? String, "忘れない")

        let recoveredMeaning = app.textFields["card-editor-answer-meaning"]
        XCTAssertTrue(recoveredMeaning.waitForExistence(timeout: 8))
        XCTAssertEqual(recoveredMeaning.value as? String, "not to forget")
        replaceText(
            in: recoveredMeaning,
            currentText: "not to forget",
            with: "always remember"
        )
        let retryPrepare = app.buttons["Prepare"]
        XCTAssertTrue(retryPrepare.isEnabled)
        retryPrepare.tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["card-editor-error"].waitForExistence(timeout: 8))

        app.terminate()
        launchFixture("create-card-recovery", reset: false, application: app)
        let restagedRecovery = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Resume audio recognition draft")
        ).firstMatch
        XCTAssertTrue(restagedRecovery.waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Resume audio recognition draft")
        ).count, 1)
        restagedRecovery.tap()
        XCTAssertTrue(app.navigationBars["Resume Draft"].waitForExistence(timeout: 8))
        let restagedMeaning = app.textFields["card-editor-answer-meaning"]
        XCTAssertTrue(restagedMeaning.waitForExistence(timeout: 8))
        XCTAssertEqual(restagedMeaning.value as? String, "always remember")
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
    func testSatoriReaderSetupIsDiscoverableOnlyThroughSettings() {
        let app = launchFixture("calendar-connection", reset: true)
        let integration = app.buttons["SatoriReaderIntegrationLink"]
        for _ in 0..<3 where !integration.exists {
            app.swipeUp()
        }
        XCTAssertTrue(integration.waitForExistence(timeout: 8))
        integration.tap()

        XCTAssertTrue(app.navigationBars["Satori Reader"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Tracking not detected"].exists)
        XCTAssertTrue(app.staticTexts["1. Track opening Satori Reader"].exists)
        let startTest = app.buttons["Start Test"]
        for _ in 0..<3 where !startTest.exists {
            app.swipeUp()
        }
        XCTAssertTrue(startTest.waitForExistence(timeout: 8))
        let openShortcuts = app.buttons["Open Shortcuts"]
        for _ in 0..<2 where !openShortcuts.exists {
            app.swipeUp()
        }
        XCTAssertTrue(openShortcuts.waitForExistence(timeout: 8))
    }

    @MainActor
    func testStudyDashboardUsesCompactSourceDrivenPresentation() {
        let app = launchFixture("study-dashboard", reset: true)
        XCTAssertTrue(app.staticTexts["Ready to learn"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.navigationBars["Study"].exists)
        XCTAssertFalse(app.staticTexts["Today"].exists)
        XCTAssertFalse(app.staticTexts["ConvoLab reviews"].exists)
        XCTAssertFalse(app.staticTexts["Learning readiness"].exists)
        XCTAssertFalse(app.staticTexts["Steady pace"].exists)
        XCTAssertTrue(app.staticTexts["Tue"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Aug 31"].exists)

        let itemSpread = app.staticTexts["Item Spread"]
        app.swipeUp()
        XCTAssertTrue(itemSpread.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["846 cards total"].exists)

        let badge = app.descendants(matching: .any)["StudyAchievementBadge.yearfire.first-ember"]
        app.swipeUp()
        XCTAssertTrue(badge.waitForExistence(timeout: 8))
        XCTAssertEqual(badge.frame.width, 128, accuracy: 1)
        XCTAssertTrue(badge.label.contains("Kept 25 cards stable for a year"))
    }

    @MainActor
    private func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == 1 AND hittable == 1"),
                object: element
            )],
            timeout: timeout
        ) == .completed
    }

    @MainActor
    private func replaceText(
        in element: XCUIElement,
        currentText: String,
        with replacement: String
    ) {
        element.coordinate(
            withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)
        ).tap()
        element.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentText.count)
        )
        element.typeText(replacement)
        XCTAssertEqual(element.value as? String, replacement)
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
