import XCTest

@MainActor
final class IPadWindowUITests: XCTestCase {
    func testStudySettingsAndJournalInBothOrientations() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires iPad")
        let device = XCUIDevice.shared
        let previous = device.orientation
        defer { device.orientation = previous.isValidInterfaceOrientation ? previous : .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            device.orientation = orientation
            let app = XCUIApplication()
            app.launchArguments = ["-ui-test-fixture", "mode-navigation", "-AppleInterfaceStyle", "Light"]
            app.launch()
            maximizeWindow(app)
            let layout = orientation.isPortrait ? "Portrait" : "Landscape"
            XCTAssertEqual(app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height, orientation.isLandscape)
            exerciseScreens(app, layout: layout)
            app.terminate()
        }
    }

    func testStudySettingsAndJournalInNarrowWindow() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires iPad")
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation", "-AppleInterfaceStyle", "Light"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(app.buttons["View queue"].waitForExistence(timeout: 10))
        if window.frame.width > 500 {
            let handle = window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
            let destination = window.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.75))
            handle.press(forDuration: 0.2, thenDragTo: destination)
        }
        let narrow = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.frame.width <= 500 }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [narrow], timeout: 5), .completed)
        exerciseScreens(app, layout: "Narrow")
        maximizeWindow(app)
    }

    func testLandscapeJournalMenusDismissKeyboardAndKeepDraft() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires iPad")
        let device = XCUIDevice.shared
        let previous = device.orientation
        defer { device.orientation = previous.isValidInterfaceOrientation ? previous : .portrait }
        device.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "mode-navigation"]
        app.launch()
        maximizeWindow(app)
        app.buttons["app-mode-picker"].tap()
        app.buttons["app-mode-journal"].tap()
        let entry = app.textViews["Journal entry"]
        let draft = "My journal draft."
        entry.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        entry.typeText(draft)
        app.buttons["app-account-menu"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.isHittable)
        capture("Avatar-menu", "Landscape")
        settings.tap()
        app.buttons["SettingsClose-Settings"].tap()
        XCTAssertEqual(entry.value as? String, draft)

        entry.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["app-mode-picker"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["app-mode-time"].isHittable)
        app.buttons["app-mode-journal"].tap()
        XCTAssertEqual(entry.value as? String, draft)
    }

    private func maximizeWindow(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let window = app.windows.firstMatch
        guard window.frame.width < springboard.frame.width - 1 else { return }
        let controls = springboard.descendants(matching: .any)["window-controls:com.cdcg.convolab"].firstMatch
        controls.tap()
        controls.buttons["Zoom-button"].tap()
        let maximized = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.frame.width >= springboard.frame.width - 1 }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [maximized], timeout: 5), .completed)
    }

    private func exerciseScreens(_ app: XCUIApplication, layout: String) {
        let queue = app.buttons["View queue"]
        XCTAssertTrue(queue.waitForExistence(timeout: 10))
        XCTAssertTrue(queue.isHittable)
        capture("Study", layout)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reviews,")).firstMatch.tap()
        let end = app.buttons["StudyEndSessionButton"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        end.tap()
        XCTAssertTrue(queue.waitForExistence(timeout: 5))
        app.buttons["app-account-menu"].tap()
        app.buttons["Settings"].tap()
        let preferences = app.buttons["SettingsChapter-Study preferences"]
        XCTAssertTrue(preferences.waitForExistence(timeout: 5))
        preferences.tap()
        XCTAssertTrue(app.steppers.firstMatch.waitForExistence(timeout: 5))
        capture("Settings", layout)
        app.buttons["SettingsClose-Settings"].tap()
        app.buttons["app-mode-picker"].tap()
        app.buttons["app-mode-journal"].tap()
        app.buttons["Contents"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A movie night")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        app.buttons["Final"].tap()
        XCTAssertTrue(app.buttons["Listen corrected version"].waitForExistence(timeout: 5))
        capture("Journal", layout)
    }

    private func capture(_ screen: String, _ layout: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(screen)-\(layout)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
