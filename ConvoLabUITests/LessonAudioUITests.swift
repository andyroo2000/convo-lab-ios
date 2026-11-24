import XCTest

final class LessonAudioUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testLessonPlayButtonUsesCurrentCardAndStopsAtNavigationAndQuiz() {
        let app = launchLesson()
        let play = app.buttons["StudyLessonAudioButton"]
        waitForPlayback("idle", in: app)
        XCTAssertTrue(play.isEnabled)
        play.tap()
        waitForPlayback("playing:first", in: app)

        app.buttons["Next"].tap()
        waitForCard(2, in: app)
        waitForPlayback("idle", in: app)
        XCTAssertFalse(play.exists)
        app.buttons["Previous"].tap()
        waitForCard(1, in: app)
        play.tap()
        waitForPlayback("playing:first", in: app)

        app.buttons["Next"].tap()
        app.buttons["Next"].tap()
        waitForCard(3, in: app)
        waitForPlayback("idle", in: app)
        XCTAssertTrue(play.exists)
        XCTAssertFalse(play.isEnabled, "Unavailable audio must not replay the preceding card")
        app.buttons["Next"].tap()
        waitForCard(4, in: app)
        XCTAssertTrue(play.isEnabled)
        play.tap()
        waitForPlayback("playing:last", in: app)
        app.buttons["Start Quiz"].tap()
        XCTAssertTrue(app.buttons["Show Answer"].waitForExistence(timeout: 5))
        let progress = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND value == %@", "Session progress", "0 of 4 complete"
        )).firstMatch
        XCTAssertTrue(progress.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Flashcard prompt and session controls"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        waitForPlayback("idle", in: app)
        XCTAssertFalse(play.exists)
    }

    @MainActor
    func testHardwareSpacePlaysOnlyTheVisiblePreviewCard() {
        let app = launchLesson()
        waitForPlayback("idle", in: app)
        app.typeKey(" ", modifierFlags: [])
        waitForPlayback("playing:first", in: app)
        XCTAssertTrue(app.staticTexts["Preview this lesson"].exists)
        XCTAssertFalse(app.buttons["Show Answer"].exists)

        app.buttons["Next"].tap()
        waitForCard(2, in: app)
        app.typeKey(" ", modifierFlags: [])
        waitForPlayback("idle", in: app)
        waitForCard(2, in: app)
        app.buttons["Next"].tap()
        waitForCard(3, in: app)
        app.typeKey(" ", modifierFlags: [])
        waitForPlayback("idle", in: app)
        app.buttons["Next"].tap()
        waitForCard(4, in: app)
        app.typeKey(" ", modifierFlags: [])
        waitForPlayback("playing:last", in: app)
        waitForCard(4, in: app)
    }

    @MainActor
    func testQuizAnswerSpeakerPlaysWithAccessibleGradeControls() {
        let app = openQuizAnswer()
        let speaker = app.buttons["StudyAnswerAudioButton"]
        XCTAssertTrue(speaker.waitForExistence(timeout: 5))
        XCTAssertTrue(speaker.isHittable)
        XCTAssertEqual(speaker.label, "Play answer audio")
        speaker.tap()
        waitForPlayback("playing:other", in: app)
        XCTAssertEqual(speaker.value as? String, "Playing")
        for title in ["Again", "Hard", "Good", "Easy"] {
            XCTAssertTrue(app.buttons[title].isHittable)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Open journal flashcard answer"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testQuizGradesRemainReachableAtLargestTextSize() {
        let app = openQuizAnswer(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        for title in ["Again", "Hard", "Good", "Easy"] {
            XCTAssertTrue(app.buttons[title].isHittable)
        }
        XCTAssertTrue(app.buttons["StudyAnswerAudioButton"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Open journal flashcard large text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func openQuizAnswer(contentSize: String? = nil) -> XCUIApplication {
        let app = launchLesson(contentSize: contentSize)
        for number in 2...4 {
            app.buttons["Next"].tap()
            waitForCard(number, in: app)
        }
        app.buttons["Start Quiz"].tap()
        app.buttons["Show Answer"].tap()
        XCTAssertTrue(app.buttons["Good"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func launchLesson(contentSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "offline-review", "-ui-test-lesson-audio"]
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        }
        app.launch()
        waitForCard(1, in: app)
        let play = app.buttons["StudyLessonAudioButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    private func waitForCard(_ number: Int, in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Card \(number) of 4"].waitForExistence(timeout: 8))
    }

    @MainActor
    private func waitForPlayback(_ value: String, in app: XCUIApplication) {
        let element = app.staticTexts["LessonFixturePlayback"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
