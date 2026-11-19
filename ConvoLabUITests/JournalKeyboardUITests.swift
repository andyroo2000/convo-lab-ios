import XCTest

@MainActor
final class JournalKeyboardUITests: XCTestCase {
    func testOnboardingRequiresChoiceAndRemembersDeviceKeyboard() {
        let app = openJournal(onboarding: true)
        let confirm = app.buttons["JournalKeyboardConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 8))
        XCTAssertFalse(confirm.isEnabled)
        XCTAssertFalse(app.staticTexts["Saved on this device."].exists)
        capture(app, "Keyboard onboarding with two miniature screens")
        app.buttons["JournalKeyboard-device"].tap()
        confirm.tap()
        let field = app.textViews["Journal entry"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("My own keyboard.")
        XCTAssertEqual(field.value as? String, "My own keyboard.")
        app.terminate()
        let reopened = openJournal(onboarding: false)
        XCTAssertFalse(reopened.buttons["JournalKeyboardConfirm"].exists)
        XCTAssertTrue(reopened.textViews["Journal entry"].exists)
        openSettings(reopened)
        XCTAssertTrue(reopened.buttons["JournalKeyboard-device"].isSelected)
        capture(reopened, "Remembered keyboard preference")
    }

    func testBuiltInConversionCandidatesAndSwitchingKeepDraftText() {
        let app = openJournal(onboarding: true)
        XCTAssertTrue(app.buttons["JournalKeyboard-builtIn"].waitForExistence(timeout: 8))
        app.buttons["JournalKeyboard-builtIn"].tap()
        app.buttons["JournalKeyboardConfirm"].tap()
        let field = app.textViews["Journal entry"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("kyouhatanoshikatta")
        let kanaReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "きょうはたのしかった"), object: field
        )
        XCTAssertEqual(XCTWaiter.wait(for: [kanaReady], timeout: 5), .completed)
        let candidate = app.collectionViews["JournalCandidates"].cells["今日は楽しかった"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 120))
        XCTAssertEqual(field.value as? String, "きょうはたのしかった", "Suggestions must not rewrite the notebook")
        let strip = app.collectionViews["JournalCandidates"]
        XCTAssertTrue(app.buttons["Close"].isHittable)
        XCTAssertTrue(app.buttons["Submit"].isHittable)
        XCTAssertLessThanOrEqual(app.buttons["Submit"].frame.maxY, strip.frame.minY)
        capture(app, "01 Kana stays in notebook with native candidate strip")
        candidate.tap()
        XCTAssertEqual(field.value as? String, "今日は楽しかった")
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(field.value as? String, "今日は楽しかっ")
        field.typeText("ta\n")
        XCTAssertEqual(field.value as? String, "今日は楽しかった")
        XCTAssertFalse(app.buttons["変換"].exists)
        capture(app, "02 Committed text with working native Delete")
        field.typeText("\name")
        let latin = strip.cells["ame"]
        XCTAssertTrue(latin.waitForExistence(timeout: 10))
        for _ in 0..<3 where !latin.isHittable { strip.swipeLeft() }
        capture(app, "04 Kana katakana and Latin spellings in the candidate strip")
        latin.tap()
        XCTAssertEqual(field.value as? String, "今日は楽しかった\name")
        let converted = field.value as? String
        dismissKeyboard(app)
        capture(app, "03 Notebook with Close and Submit unobstructed")
        openSettings(app)
        app.buttons["JournalKeyboard-device"].tap()
        app.buttons["JournalKeyboardConfirm"].tap()
        XCTAssertEqual(app.textViews["Journal entry"].value as? String, converted)
        openSettings(app)
        app.buttons["JournalKeyboard-builtIn"].tap()
        app.buttons["JournalKeyboardConfirm"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, converted)
        field.tap()
        field.typeText("hon")
        let pending = field.value as? String
        XCTAssertTrue(pending?.contains("ほn") == true)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Keep writing"].waitForExistence(timeout: 5))
        app.buttons["Keep writing"].tap()
        XCTAssertEqual(field.value as? String, pending?.replacingOccurrences(of: "ほn", with: "ほん"))
    }

    func testBuiltInFinalEditingSavesAndReopensTheConvertedText() {
        let app = openJournal(onboarding: true)
        XCTAssertTrue(app.buttons["JournalKeyboard-device"].waitForExistence(timeout: 8))
        app.buttons["JournalKeyboard-device"].tap()
        app.buttons["JournalKeyboardConfirm"].tap()
        app.buttons["My entries"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A movie night")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        app.buttons["Final"].tap()
        openSettings(app)
        app.buttons["JournalKeyboard-builtIn"].tap()
        app.buttons["JournalKeyboardConfirm"].tap()
        app.buttons["More journal options"].firstMatch.tap()
        app.buttons["Edit final"].tap()
        let field = app.textViews["Final text"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("ohayou\n")
        let edited = field.value as? String
        XCTAssertTrue(edited?.contains("おはよう") == true)
        dismissKeyboard(app)
        for _ in 0..<8 where !app.buttons["Save changes"].isHittable { app.swipeUp() }
        app.buttons["Save changes"].tap()
        XCTAssertTrue(app.buttons["Listen corrected version"].waitForExistence(timeout: 10))
        app.buttons["More journal options"].firstMatch.tap()
        app.buttons["Edit final"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, edited)
        capture(app, "Saved final text with built-in input")
    }

    private func openJournal(onboarding: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation", onboarding ? "-journal-keyboard-onboarding" : "-journal-keyboard-keep"]
        app.launch()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["app-mode-picker"].label.contains("Journal"))
        return app
    }

    private func openSettings(_ app: XCUIApplication) {
        for _ in 0..<8 where !app.buttons["More journal options"].firstMatch.isHittable { app.swipeDown() }
        app.buttons["More journal options"].firstMatch.tap()
        XCTAssertTrue(app.buttons["JournalKeyboardMenu"].waitForExistence(timeout: 5))
        capture(app, "Keyboard below Appearance in the Journal menu")
        app.buttons["JournalKeyboardMenu"].tap()
        XCTAssertTrue(app.buttons["JournalKeyboardConfirm"].waitForExistence(timeout: 5))
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
