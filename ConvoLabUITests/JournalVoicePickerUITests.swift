import XCTest

final class JournalVoicePickerUITests: XCTestCase {
    @MainActor
    func testVoicePickerShowsChoicesAndCancelPreservesSelection() {
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
        let picker = app.buttons["JournalVoicePicker"]
        for _ in 0..<3 where !picker.isHittable { app.swipeUp() }
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        verifyEntryLayout(app, picker: picker)
        let selected = picker.value as? String
        picker.tap()
        let title = app.staticTexts["Choose your narration voice"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(title.frame.minY, picker.frame.maxY)
        XCTAssertGreaterThan(app.buttons["Play corrected version"].frame.minY, title.frame.maxY)
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

    @MainActor
    private func verifyEntryLayout(_ app: XCUIApplication, picker: XCUIElement) {
        let copy = app.buttons["Copy final text"]
        XCTAssertGreaterThan(picker.frame.minX, copy.frame.minX)
        XCTAssertEqual(picker.frame.midY, copy.frame.midY, accuracy: 2)
        let date = app.staticTexts["JournalEntryDate"]
        XCTAssertEqual(date.label, "2026.11.12")
        XCTAssertGreaterThan(date.frame.minY, app.staticTexts["A movie night"].frame.maxY)
        XCTAssertLessThan(date.frame.maxY, copy.frame.minY)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Journal title date and aligned audio controls"
        preview.lifetime = .keepAlways
        add(preview)
    }

}
