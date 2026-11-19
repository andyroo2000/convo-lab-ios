import XCTest

final class JournalEditingUITests: XCTestCase {
    @MainActor
    func testDraftAndFinalShowOnlyOneVersionAtATime() {
        let app = openEntry()
        XCTAssertTrue(app.buttons["Final"].isSelected)
        XCTAssertTrue(app.buttons["Listen corrected version"].exists)
        let finalPreview = XCTAttachment(screenshot: app.screenshot())
        finalPreview.name = "Final selected"
        finalPreview.lifetime = .keepAlways
        add(finalPreview)
        app.buttons["Draft"].tap()
        let edited = app.descendants(matching: .any)["JournalHighlightedEntry"].firstMatch
        XCTAssertTrue(edited.label.contains("Replace 映画を見た。 with 映画を見ました。"))
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Soft highlights and corrected version"
        preview.lifetime = .keepAlways
        add(preview)
        XCTAssertFalse(app.staticTexts["Correction"].exists)
        XCTAssertFalse(app.staticTexts["Optional change"].exists)
        XCTAssertFalse(app.buttons["Listen corrected version"].exists)
        app.buttons["Final"].tap()
        XCTAssertTrue(app.buttons["Listen corrected version"].exists)
        XCTAssertFalse(edited.exists)
        app.buttons["Draft"].tap()
        XCTAssertTrue(edited.exists)
        app.terminate()
        let reopened = openEntry(resetVersion: false)
        XCTAssertTrue(reopened.buttons["Draft"].isSelected)
        XCTAssertFalse(reopened.buttons["Listen corrected version"].exists)
    }

    @MainActor
    func testFinalEditorCancelsAndSavesOnNotebookPaper() {
        let app = openEntry()
        let edit = app.buttons["Edit final"]
        app.buttons["More journal options"].firstMatch.tap()
        edit.tap()
        let field = app.textViews["Final text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Draft"].isEnabled)
        XCTAssertFalse(app.buttons["Final"].isEnabled)
        let original = field.value as? String
        XCTAssertFalse(app.buttons["Listen corrected version"].exists)
        field.tap()
        field.typeText(" Discard this change.")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Draft"].isEnabled)
        app.buttons["More journal options"].firstMatch.tap()
        edit.tap()
        XCTAssertEqual(field.value as? String, original)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Edit final on notebook paper"
        preview.lifetime = .keepAlways
        add(preview)
        field.tap()
        field.typeText(" A new final sentence.")
        app.buttons["Save changes"].tap()
        XCTAssertTrue(app.buttons["Listen corrected version"].waitForExistence(timeout: 5))
        app.buttons["More journal options"].firstMatch.tap()
        edit.tap()
        XCTAssertTrue((field.value as? String)?.contains("A new final sentence.") == true)
        app.buttons["Cancel"].tap()
    }

    @MainActor
    func testPickerFitsAtLargestTextSize() {
        let app = openEntry(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        for label in ["Draft", "Final"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX)
            button.tap()
            XCTAssertTrue(button.isSelected)
        }
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Picker at largest accessibility text size"
        preview.lifetime = .keepAlways
        add(preview)
    }

    @MainActor
    func testCopyFollowsTheSelectedVersionWithoutEditButtons() {
        let app = openEntry()
        XCTAssertFalse(app.buttons["Edit entry"].exists)
        app.buttons["Draft"].tap()
        app.buttons["More journal options"].firstMatch.tap()
        app.buttons["Copy text"].tap()
        XCTAssertTrue(app.buttons["Final"].waitForExistence(timeout: 5))
        app.buttons["Final"].tap()
        app.buttons["More journal options"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Edit final"].exists)
        app.buttons["Copy text"].tap()
        app.buttons["Draft"].tap()
        app.buttons["More journal options"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Copy text"].exists)
        XCTAssertFalse(app.buttons["Edit final"].exists)
    }

    @MainActor
    func testCorrectionBubbleHasNoMutationControls() {
        inspectCorrection(openEntry())
    }

    @MainActor
    func testCorrectionPopoverFollowsJournalFontSize() {
        let small = openEntry(fontSize: 16)
        inspectCorrection(small)
        let smallHeight = small.otherElements["JournalCorrectionPopover"].firstMatch.frame.height
        small.terminate()
        let large = openEntry(fontSize: 30)
        inspectCorrection(large)
        let largeHeight = large.otherElements["JournalCorrectionPopover"].firstMatch.frame.height
        XCTAssertGreaterThan(largeHeight, smallHeight + 20)
    }

    @MainActor
    func testLongCorrectionStaysInsideScreenAndScrollsAtLargeText() {
        let app = openEntry(contentSize: "UICTContentSizeCategoryAccessibilityL", longCorrection: true)
        inspectCorrection(app)
        let scroll = app.scrollViews["JournalCorrectionScroll"].firstMatch
        XCTAssertTrue(scroll.exists)
        XCTAssertGreaterThanOrEqual(scroll.frame.minY, app.frame.minY)
        XCTAssertLessThanOrEqual(scroll.frame.maxY, app.frame.maxY)
        let explanation = scroll.textViews.matching(NSPredicate(format: "value CONTAINS %@", "End of explanation.")).firstMatch
        let initialTop = explanation.frame.minY
        for _ in 0..<12 { scroll.swipeUp() }
        XCTAssertTrue(explanation.exists)
        XCTAssertLessThan(explanation.frame.minY, initialTop)
        XCTAssertLessThanOrEqual(explanation.frame.maxY, scroll.frame.maxY)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Long correction scrolled to end"
        preview.lifetime = .keepAlways
        add(preview)
        XCTAssertFalse(app.buttons["Reject correction"].exists)
    }

    @MainActor
    private func inspectCorrection(_ app: XCUIApplication) {
        app.buttons["Draft"].tap()
        let highlighted = app.descendants(matching: .any)["JournalHighlightedEntry"].firstMatch
        highlighted.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.15)).tap()
        let popup = app.otherElements["JournalCorrectionPopover"].firstMatch
        XCTAssertTrue(popup.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Apply suggestion"].exists)
        XCTAssertFalse(app.buttons["Reject correction"].exists)
        XCTAssertFalse(app.staticTexts["Applied"].exists)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Web-style correction bubble"
        preview.lifetime = .keepAlways
        add(preview)
    }

    @MainActor
    private func openEntry(contentSize: String? = nil, resetVersion: Bool = true, longCorrection: Bool = false, fontSize: Int = 20) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation", "-AppleInterfaceStyle", "Dark", "-reading-theme", "system", "-reading-format", "Phone reader"]
        app.launchArguments += ["-journal.typography.size", String(fontSize)]
        if let contentSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize] }
        if longCorrection { app.launchArguments += ["-journal-long-correction"] }
        app.launch()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 8))
        app.buttons["app-mode-picker"].tap()
        app.buttons["app-mode-journal"].tap()
        XCTAssertTrue(app.buttons["My entries"].waitForExistence(timeout: 5))
        app.buttons["My entries"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A movie night")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.buttons["Draft"].waitForExistence(timeout: 5))
        if resetVersion { app.buttons["Final"].tap() }
        return app
    }
}
