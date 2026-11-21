import XCTest

final class JournalAppearanceUITests: XCTestCase {
    @MainActor
    func testAppearancePersistsAcrossRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation"]
        openAppearance(app)
        XCTAssertFalse(app.buttons["Done"].exists)
        XCTAssertEqual(app.staticTexts["JournalAppearancePreview"].label, "今日はいい一日でした。")
        XCTAssertTrue(app.buttons["Close appearance"].isHittable)
        app.buttons["Serif"].tap()
        app.sliders["Font size"].adjust(toNormalizedSliderPosition: 0.85)
        let size = app.sliders["Font size"].value as? String
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Journal font cards and slider"
        preview.lifetime = .keepAlways
        add(preview)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        app.terminate()
        openAppearance(app)
        XCTAssertTrue(app.buttons["Serif"].isSelected)
        XCTAssertEqual(app.sliders["Font size"].value as? String, size)
        app.buttons["Sans-serif"].tap()
        app.sliders["Font size"].adjust(toNormalizedSliderPosition: 0.28)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
    }

    @MainActor
    func testOutsideTapClosesAppearanceAndItCanReopen() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation"]
        openAppearance(app)
        XCTAssertTrue(app.staticTexts["Journal appearance"].exists)
        XCTAssertFalse(app.staticTexts["Font"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(app.sliders["Font size"].waitForNonExistence(timeout: 5))
        app.buttons["app-account-menu"].tap()
        app.buttons["Appearance"].tap()
        XCTAssertTrue(app.sliders["Font size"].waitForExistence(timeout: 5))
        app.buttons["Close appearance"].tap()
        XCTAssertTrue(app.sliders["Font size"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func openAppearance(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 8))
        app.buttons["app-mode-picker"].tap()
        app.buttons["app-mode-journal"].tap()
        XCTAssertTrue(app.buttons["Contents"].waitForExistence(timeout: 5))
        app.buttons["Contents"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A movie night")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        app.buttons["app-account-menu"].tap()
        let appearance = app.buttons["Appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        XCTAssertTrue(app.sliders["Font size"].waitForExistence(timeout: 5))
    }
}
