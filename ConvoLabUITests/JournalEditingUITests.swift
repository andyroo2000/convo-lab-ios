import XCTest

final class JournalEditingUITests: XCTestCase {
    @MainActor
    func testDraftAndFinalShowOnlyOneVersionAtATime() {
        let app = openEntry()
        XCTAssertTrue(app.buttons["Final"].isSelected)
        XCTAssertTrue(app.buttons["Play corrected version"].exists)
        app.buttons["Draft"].tap()
        let edited = app.descendants(matching: .any)["JournalHighlightedEntry"].firstMatch
        XCTAssertTrue(edited.label.contains("Replace 映画を見た。 with 映画を見ました。"))
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Soft highlights and corrected version"
        preview.lifetime = .keepAlways
        add(preview)
        XCTAssertFalse(app.staticTexts["Correction"].exists)
        XCTAssertFalse(app.staticTexts["Optional change"].exists)
        XCTAssertFalse(app.buttons["Play corrected version"].exists)
        app.buttons["Final"].tap()
        XCTAssertTrue(app.buttons["Play corrected version"].exists)
        XCTAssertFalse(edited.exists)
        app.buttons["Draft"].tap()
        XCTAssertTrue(edited.exists)
        app.terminate()
        let reopened = openEntry()
        XCTAssertTrue(reopened.buttons["Final"].isSelected)
        XCTAssertTrue(reopened.buttons["Play corrected version"].exists)
    }

    @MainActor
    func testCopyFollowsTheSelectedVersionWithoutEditButtons() {
        let app = openEntry()
        XCTAssertFalse(app.buttons["Edit entry"].exists)
        app.buttons["Draft"].tap()
        app.buttons["Copy draft text"].tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 5))
        app.buttons["Final"].tap()
        XCTAssertTrue(app.buttons["Copy final text"].exists)
        XCTAssertFalse(app.buttons["Edit corrected version"].exists)
        app.buttons["Copy final text"].tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 5))
        app.buttons["Draft"].tap()
        XCTAssertTrue(app.buttons["Copy draft text"].exists)
    }

    @MainActor
    func testOptionalSuggestionHasApplyThenUndoControls() {
        exerciseOptionalChange(openEntry())
    }

    @MainActor
    func testLargeTextSuggestionControlsStackAndRemainUsable() {
        let app = openEntry(contentSize: "UICTContentSizeCategoryAccessibilityL")
        exerciseOptionalChange(app)
        XCTAssertLessThanOrEqual(app.staticTexts["Original kept"].frame.maxY, app.buttons["Apply suggestion"].frame.minY)
    }

    @MainActor
    private func exerciseOptionalChange(_ app: XCUIApplication) {
        app.buttons["Draft"].tap()
        let highlighted = app.descendants(matching: .any)["JournalHighlightedEntry"].firstMatch
        highlighted.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.25)).tap()
        let apply = app.buttons["Apply suggestion"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertTrue(apply.isHittable)
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
    private func openEntry(contentSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation", "-AppleInterfaceStyle", "Dark", "-reading-theme", "system", "-reading-format", "Phone reader"]
        if let contentSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize] }
        app.launch()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 8))
        app.buttons["StudyJournalLink"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A movie night")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.buttons["Draft"].waitForExistence(timeout: 5))
        return app
    }
}
