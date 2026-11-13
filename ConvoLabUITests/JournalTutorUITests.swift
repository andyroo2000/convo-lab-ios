import XCTest

final class JournalTutorUITests: XCTestCase {
    @MainActor
    func testTutorChoicePersistsAndDoesNotReassignAnOlderQuestion() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation", "-AppleInterfaceStyle", "Dark"]
        app.launch()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 8))
        app.buttons["StudyJournalLink"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A movie night")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        for _ in 0..<3 { app.swipeUp() }
        let hana = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Hana (F)")).firstMatch
        XCTAssertTrue(hana.waitForExistence(timeout: 5))
        hana.tap()
        let portrait = app.images["Hana, your tutor"]
        XCTAssertTrue(portrait.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["What kind of movie was it?"].exists)
        XCTAssertTrue(app.buttons["Play question"].exists)
        XCTAssertFalse(app.buttons["Pause question"].exists)
        app.buttons["Choose tutor"].tap()
        let ren = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Ren (M)")).firstMatch
        XCTAssertTrue(ren.waitForExistence(timeout: 5))
        ren.tap()
        XCTAssertTrue(portrait.waitForExistence(timeout: 5))
        app.buttons["Choose tutor"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Ren (M)", "Current default")).firstMatch.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Journal tutor picker keeps the existing question with Hana"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
