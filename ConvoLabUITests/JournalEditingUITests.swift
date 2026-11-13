import XCTest

final class JournalEditingUITests: XCTestCase {
    @MainActor
    func testManualCorrectedEditCanBeSavedAndReopened() {
        let app = openEntry()
        app.buttons["Edit corrected version"].tap()
        let editor = app.textViews["Corrected entry text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(" Added detail.")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Edit corrected version"].waitForExistence(timeout: 5))
        app.buttons["Edit corrected version"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String ?? "").contains("Added detail."))
        app.buttons["Cancel"].tap()
    }

    @MainActor
    func testOptionalSuggestionHasApplyThenUndoControls() {
        let app = openEntry()
        let highlighted = app.descendants(matching: .any)["JournalHighlightedEntry"].firstMatch
        highlighted.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        let apply = app.buttons["Apply suggestion"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Original kept"].exists)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Quiet footer — optional change"
        preview.lifetime = .keepAlways
        add(preview)
        apply.tap()
        let undo = app.buttons["Undo suggestion"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Applied"].exists)
        undo.tap()
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Original kept"].exists)
    }

    @MainActor
    private func openEntry() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation", "-AppleInterfaceStyle", "Dark", "-reading-theme", "system", "-reading-format", "Phone reader"]
        app.launch()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 8))
        app.buttons["StudyJournalLink"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A movie night")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.buttons["Edit corrected version"].waitForExistence(timeout: 5))
        return app
    }
}
