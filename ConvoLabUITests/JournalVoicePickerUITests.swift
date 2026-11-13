import XCTest

final class JournalVoicePickerUITests: XCTestCase {
    @MainActor
    func testVoicePickerShowsChoicesAndCancelPreservesSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation"]
        app.launch()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 8))
        app.buttons["StudyJournalLink"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A movie night")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.buttons["Final"].waitForExistence(timeout: 5))
        app.buttons["Final"].tap()
        let picker = app.buttons["JournalVoicePicker"]
        for _ in 0..<3 where !picker.isHittable { app.swipeUp() }
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let selected = picker.value as? String
        picker.tap()
        let title = app.staticTexts["Choose your narration voice"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(title.exists)
        XCTAssertEqual(picker.value as? String, selected)
        picker.tap()
        let haru = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Haru (M)")).firstMatch
        XCTAssertTrue(haru.waitForExistence(timeout: 5))
        haru.tap()
        XCTAssertFalse(title.exists)
        XCTAssertEqual(picker.value as? String, "Haru (M)")
    }
}
