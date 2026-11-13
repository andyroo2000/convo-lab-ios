import XCTest

final class JournalDeletionUITests: XCTestCase {
    @MainActor
    func testDraftDeletionRequiresConfirmationAndReturnsToJournal() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation"]
        app.launch()
        XCTAssertTrue(app.buttons["StudyJournalLink"].waitForExistence(timeout: 8))
        app.buttons["StudyJournalLink"].tap()
        XCTAssertTrue(app.buttons["JournalNewEntry"].waitForExistence(timeout: 5))
        app.buttons["JournalNewEntry"].tap()
        let delete = app.buttons["JournalDeleteEntry"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        if !delete.isHittable { app.swipeUp() }
        delete.tap()
        XCTAssertTrue(app.buttons["Keep entry"].waitForExistence(timeout: 5))
        app.buttons["Keep entry"].tap()
        XCTAssertTrue(delete.exists)
        delete.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Delete entry", "JournalDeleteEntry")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["JournalNewEntry"].waitForExistence(timeout: 5))
        XCTAssertFalse(delete.exists)
    }
}
