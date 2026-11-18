import XCTest

@MainActor
final class TypingPlaygroundUITests: XCTestCase {
  func testNativeNotebookConvertsAndExposesTouchSectionControls() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-test-fixture", "typing-playground"]
    app.launch()
    let ready = app.webViews.staticTexts["Ready to write · Neural conversion"]
    XCTAssertTrue(ready.waitForExistence(timeout: 120))
    let field = app.webViews.textViews.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    if app.buttons["Continue"].waitForExistence(timeout: 2) { app.buttons["Continue"].tap() }
    field.typeText("hashidetabemashita")
    let converted = NSPredicate(format: "value == %@", "箸で食べました")
    expectation(for: converted, evaluatedWith: field)
    waitForExpectations(timeout: 30)
    XCTAssertTrue(app.webViews.buttons["Shorten"].exists)
    XCTAssertTrue(app.webViews.buttons["Lengthen"].exists)
    app.webViews.buttons["Convert"].tap()
    XCTAssertTrue(app.webViews.switches["箸で"].waitForExistence(timeout: 10))
    app.webViews.switches["橋で"].tap()
    XCTAssertEqual(field.value as? String, "橋で食べました")
    app.webViews.buttons["Shorten"].tap()
    XCTAssertTrue(app.webViews.staticTexts["More choices ready · ↑ ↓ choose · ← → sections · Enter to commit."].waitForExistence(timeout: 60))
    let menu = XCTAttachment(screenshot: app.screenshot())
    menu.name = "Neural candidates after shortening a section"
    menu.lifetime = .keepAlways
    add(menu)
    app.webViews.buttons["Commit"].tap()
    let capture = XCTAttachment(screenshot: app.screenshot())
    capture.name = "Typing playground with native conversion"
    capture.lifetime = .keepAlways
    add(capture)
  }

  func testBenchmarkRunsAndOffersAReport() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-test-fixture", "typing-playground"]
    app.launch()
    XCTAssertTrue(
      app.webViews.staticTexts["Ready to write · Neural conversion"].waitForExistence(timeout: 120))
    app.buttons["Benchmark"].tap()
    app.buttons["Run benchmark"].tap()
    XCTAssertTrue(app.buttons["Share benchmark results"].waitForExistence(timeout: 240))
    XCTAssertTrue(app.staticTexts["Results"].exists)
    let capture = XCTAttachment(screenshot: app.screenshot())
    capture.name = "Completed on-device benchmark"
    capture.lifetime = .keepAlways
    add(capture)
  }
}
