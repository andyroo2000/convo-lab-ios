import XCTest

final class JournalTutorUITests: XCTestCase {
    @MainActor
    func testTutorChoicePersistsAndDoesNotReassignAnOlderQuestion() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation", "-AppleInterfaceStyle", "Light", "-journal.typography.font", "klee", "-journal.typography.size", "20"]
        app.launchEnvironment["JOURNAL_FIXTURE_AVATARS"] = ProcessInfo.processInfo.environment["JOURNAL_FIXTURE_AVATARS"]
        app.launch()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 8))
        app.buttons["app-mode-picker"].tap()
        app.buttons["app-mode-journal"].tap()
        XCTAssertTrue(app.buttons["Contents"].waitForExistence(timeout: 5))
        app.buttons["Contents"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A movie night")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        for _ in 0..<3 { app.swipeUp() }
        let hana = app.buttons["Hana"]
        XCTAssertTrue(hana.waitForExistence(timeout: 5))
        hana.tap()
        let portrait = app.images["Hana, your tutor"]
        XCTAssertTrue(portrait.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["What kind of movie was it?"].exists)
        let listen = app.buttons["Listen question"]
        XCTAssertTrue(listen.exists)
        XCTAssertEqual(listen.frame.midY, app.buttons["Show English"].frame.midY, accuracy: 2)
        XCTAssertFalse(app.sliders["question audio position"].exists)
        XCTAssertFalse(app.buttons["Pause question"].exists)
        let contents = app.buttons["Contents"]
        XCTAssertLessThan(contents.frame.height, 50)
        XCTAssertTrue(contents.isHittable)
        for _ in 0..<4 { app.swipeDown() }
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Generous Journal with illustrated tutor"
        preview.lifetime = .keepAlways
        add(preview)
        app.buttons["app-account-menu"].tap()
        app.buttons["Choose your tutor"].tap()
        let ren = app.buttons["Ren"]
        XCTAssertTrue(ren.waitForExistence(timeout: 5))
        ren.tap()
        XCTAssertTrue(portrait.waitForExistence(timeout: 5))
        app.buttons["app-account-menu"].tap()
        app.buttons["Choose your tutor"].tap()
        XCTAssertTrue(ren.waitForExistence(timeout: 5))
        XCTAssertTrue(ren.isSelected)
        XCTAssertFalse(app.staticTexts["Ren (M)"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Journal tutor picker keeps the existing question with Hana"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
