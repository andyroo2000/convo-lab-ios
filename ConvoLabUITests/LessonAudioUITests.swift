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
    private func launchLesson() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "offline-review", "-ui-test-lesson-audio"]
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
