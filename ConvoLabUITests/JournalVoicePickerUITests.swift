import XCTest

final class JournalVoicePickerUITests: XCTestCase {
    @MainActor
    func testCompactPlayerAndDrawerActions() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation"]
        app.launch()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 8))
        app.buttons["app-mode-picker"].tap()
        app.buttons["app-mode-journal"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A movie night")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.buttons["Final"].waitForExistence(timeout: 5))
        app.buttons["Final"].tap()
        let listen = app.buttons["Listen corrected version"]
        XCTAssertTrue(listen.waitForExistence(timeout: 5))
        XCTAssertLessThan(listen.frame.maxY, app.staticTexts["JournalEntryDate"].frame.minY)
        checkSeeking(app)
        attach(app, "Final notebook with compact audio header")
        app.buttons["More journal options"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Copy text"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Edit final"].exists)
        app.buttons["JournalVoicePicker"].tap()
        let title = app.staticTexts["Choose your narration voice"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        attach(app, "Narration voice modal")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Resume corrected version"].waitForExistence(timeout: 5))
        app.buttons["My entries"].tap()
        XCTAssertTrue(app.buttons["JournalNewEntry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["JournalRowActions-01arz3ndektsv4rrffq69g5fav"].exists)
        attach(app, "My entries drawer")
        app.buttons["JournalNewEntry"].tap()
        XCTAssertTrue(app.textViews["Journal entry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Title"].exists)
        attach(app, "New draft notebook")
    }

    @MainActor
    private func checkSeeking(_ app: XCUIApplication) {
        app.buttons["Listen corrected version"].tap()
        let pause = app.buttons["Pause corrected version"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        let ribbon = app.descendants(matching: .any).matching(identifier: "Corrected version audio position").firstMatch
        XCTAssertTrue(ribbon.exists)
        ribbon.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.85)).tap()
        XCTAssertEqual(ribbon.value as? String, "75 percent")
        let from = ribbon.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.85))
        let to = ribbon.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.85))
        from.press(forDuration: 0.1, thenDragTo: to)
        XCTAssertEqual(ribbon.value as? String, "25 percent")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
