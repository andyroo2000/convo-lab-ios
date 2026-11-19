import XCTest

final class JournalClarificationUITests: XCTestCase {
    @MainActor
    func testQuestionsReplaceEachOtherBeforeTheReplyAppears() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation", "-journal-clarification-fixture", "-journal-slow-clarification", "-AppleInterfaceStyle", "Dark"]
        app.launch()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 8))
        app.buttons["app-mode-picker"].tap()
        app.buttons["app-mode-journal"].tap()
        XCTAssertTrue(app.buttons["Contents"].waitForExistence(timeout: 5))
        app.buttons["Contents"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A movie night")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        let hana = app.buttons["Hana"]
        for _ in 0..<3 where !hana.isHittable { app.swipeUp() }
        XCTAssertTrue(hana.waitForExistence(timeout: 5))
        hana.tap()
        let answer = app.textViews["Your answer"]
        for _ in 0..<3 where !answer.isHittable { app.swipeUp() }
        answer.tap()
        answer.typeText("I drove while Molly looked up the movie.")
        app.buttons["Done"].tap()
        app.buttons["Submit"].tap()
        let first = app.staticTexts["Who was driving?"]
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Answer"].isEnabled)
        XCTAssertFalse(app.otherElements["Your reply"].exists)
        app.buttons["I did"].tap()
        for _ in 0..<2 where !app.buttons["Answer"].isHittable { app.swipeUp() }
        app.buttons["Answer"].tap()
        XCTAssertTrue(app.staticTexts["Who looked up the movie?"].waitForExistence(timeout: 5))
        XCTAssertFalse(first.exists)
        XCTAssertFalse(app.buttons["Answer"].isEnabled)
        XCTAssertFalse(app.otherElements["Your reply"].exists)
        app.buttons["Molly did"].tap()
        app.buttons["Answer"].tap()
        let thinking = app.buttons["Hide English"]
        XCTAssertTrue(thinking.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Molly did"].exists)
        XCTAssertFalse(app.buttons["Back to draft"].exists)
        let hideEnglish = app.buttons["Hide English"]
        for _ in 0..<3 where !hideEnglish.isHittable { app.swipeUp() }
        hideEnglish.tap()
        XCTAssertFalse(app.staticTexts["I'm preparing your feedback. Your writing is saved."].exists)
        XCTAssertTrue(app.staticTexts["Molly did"].exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Molly did"].isHittable)
        let thinkingPreview = XCTAttachment(screenshot: app.screenshot())
        thinkingPreview.name = "Saved clarification answer with English hidden"
        thinkingPreview.lifetime = .keepAlways
        add(thinkingPreview)
        let reply = app.otherElements["Your reply"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["Who looked up the movie?"].exists)
        XCTAssertFalse(app.buttons["Back to draft"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "Final").count, 2)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Clarification returns to the existing journal feedback"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
