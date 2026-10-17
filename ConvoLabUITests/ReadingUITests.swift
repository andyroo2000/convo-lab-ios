import XCTest

final class ReadingUITests: XCTestCase {
    @MainActor
    func testSentenceSelectionTranslationAndPagePicker() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "readings", "-ui-test-reset", "-AppleInterfaceStyle", "Dark"]
        app.launch()
        let reading = app.buttons["reading-library-reading"]
        XCTAssertTrue(reading.waitForExistence(timeout: 8))
        reading.tap()
        let sentence = app.webViews.buttons["森の中に、小さな犬がいました。"]
        XCTAssertTrue(sentence.waitForExistence(timeout: 8))
        sentence.tap()
        XCTAssertTrue(app.webViews.buttons["Play selected sentence"].waitForExistence(timeout: 3))
        sentence.tap()
        XCTAssertTrue(app.webViews.staticTexts["There was a little dog in the forest."].waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Ink cobalt quiet card"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Page 24, choose page"].tap()
        app.buttons["Page 25"].tap()
        XCTAssertTrue(app.webViews.buttons["犬は家へ帰りました。"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["-ui-test-fixture", "readings"]
        app.launch()
        let resume = app.buttons["reading-continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 8))
        resume.tap()
        XCTAssertTrue(app.buttons["Page 25, choose page"].waitForExistence(timeout: 8))
    }
}
