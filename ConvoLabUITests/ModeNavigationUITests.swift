import XCTest

final class ModeNavigationUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testRootActionsStayInModeRowAndManagementHasNoMoreParent() {
        let app = launchShell()
        let sync = app.buttons["StudySyncButton"]
        assertInModeRow(sync, app: app)
        attachModeMenu(app, currentMode: "study")
        let initialY = sync.frame.midY
        app.swipeUp()
        XCTAssertEqual(sync.frame.midY, initialY, accuracy: 2)
        XCTAssertTrue(sync.isHittable)
        selectMode("cards", app: app)
        assertInModeRow(app.buttons["CardsCreateButton"], app: app)
        assertInModeRow(app.buttons["CardsMoreButton"], app: app)
        XCTAssertFalse(app.navigationBars["Cards"].exists)
        attachScreenshot(app, name: "Cards compact header in dark device appearance")
        for mode in ["time", "settings"] {
            selectMode(mode, app: app)
            XCTAssertFalse(app.navigationBars["More"].exists)
            XCTAssertFalse(app.buttons["More"].exists)
            XCTAssertFalse(app.navigationBars.buttons["Back"].exists)
            XCTAssertFalse(app.tabBars.firstMatch.exists)
            attachScreenshot(app, name: "\(mode) root without More navigation")
        }
        assertSettingsDetailBack(app)
        selectMode("study", app: app)
        assertInModeRow(sync, app: app)
    }

    @MainActor
    func testCardsQueueEditingSelectionAndSearchRemainAvailable() {
        let app = launchShell()
        selectMode("cards", app: app)
        let firstCard = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", "First queued card"
        )).firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 8))
        toggleQueueEditing(app, expectedLabel: "Edit queue")
        let reorder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder")).firstMatch
        XCTAssertTrue(reorder.waitForExistence(timeout: 3))
        XCTAssertTrue(reorder.isHittable)
        app.segmentedControls.buttons["All Cards"].tap()
        XCTAssertFalse(app.buttons["CardsMoreButton"].exists)
        app.segmentedControls.buttons["Queue"].tap()
        XCTAssertFalse(reorder.exists)
        toggleQueueEditing(app, expectedLabel: "Edit queue")
        selectMode("study", app: app)
        selectMode("cards", app: app)
        XCTAssertFalse(reorder.exists)
        toggleQueueEditing(app, expectedLabel: "Edit queue")
        toggleQueueEditing(app, expectedLabel: "Done editing")
        app.buttons["CardsMoreButton"].tap()
        app.buttons["Study Lesson Cards Now"].tap()
        let next = app.buttons["CardsNextSelectionButton"]
        assertInModeRow(next, app: app)
        XCTAssertFalse(next.isEnabled)
        firstCard.tap()
        XCTAssertTrue(next.isEnabled)
        next.tap()
        let setup = app.alerts["Study lesson cards now"]
        XCTAssertTrue(setup.waitForExistence(timeout: 3))
        setup.buttons["Cancel"].tap()
        app.buttons["CardsCancelSelectionButton"].tap()
        assertInModeRow(app.buttons["CardsCreateButton"], app: app)
        app.segmentedControls.buttons["All Cards"].tap()
        let search = app.textFields["CardsSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        search.tap()
        search.typeText("forest")
        XCTAssertEqual(search.value as? String, "forest")
    }

    @MainActor
    func testReadingKeepsItsPageAndHierarchyAcrossModeSwitches() {
        let app = launchShell()
        selectMode("readings", app: app)
        let book = app.buttons["reading-library-navigation-book"]
        XCTAssertTrue(book.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["reading-back"].exists)
        attachScreenshot(app, name: "Readings light mode header in dark device appearance")
        attachModeMenu(app, currentMode: "readings")
        book.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "小さな犬")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Theme: Ink & cobalt"].waitForExistence(timeout: 8))
        app.buttons["Page 24, choose page"].tap()
        app.buttons["Page 25"].tap()
        XCTAssertTrue(app.buttons["Page 25, choose page"].waitForExistence(timeout: 5))
        selectMode("study", app: app)
        assertInModeRow(app.buttons["StudySyncButton"], app: app)
        selectMode("readings", app: app)
        XCTAssertTrue(app.buttons["Page 25, choose page"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["reading-back"].isHittable)
        attachScreenshot(app, name: "Reader retained after switching modes")
        app.buttons["reading-back"].tap()
        XCTAssertTrue(app.buttons["reading-book-back"].waitForExistence(timeout: 5))
        app.buttons["reading-book-back"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 5))
    }

    @MainActor
    private func launchShell() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-test-fixture", "mode-navigation", "-AppleInterfaceStyle", "Dark",
            "-reading-theme", "system", "-reading-format", "Phone reader",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    private func selectMode(_ mode: String, app: XCUIApplication) {
        app.buttons["app-mode-picker"].tap()
        let destination = app.buttons["app-mode-\(mode)"]
        XCTAssertTrue(destination.waitForExistence(timeout: 3))
        destination.tap()
        XCTAssertTrue(app.buttons["app-mode-picker"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func assertInModeRow(_ action: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertTrue(action.isHittable)
        let picker = app.buttons["app-mode-picker"]
        XCTAssertEqual(action.frame.midY, picker.frame.midY, accuracy: 3)
        XCTAssertGreaterThanOrEqual(action.frame.minX, picker.frame.maxX)
    }

    @MainActor
    private func toggleQueueEditing(_ app: XCUIApplication, expectedLabel: String) {
        app.buttons["CardsMoreButton"].tap()
        let edit = app.buttons["CardsEditQueueButton"]
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        XCTAssertEqual(edit.label, expectedLabel)
        edit.tap()
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attachModeMenu(_ app: XCUIApplication, currentMode: String) {
        app.buttons["app-mode-picker"].tap()
        let destination = app.buttons["app-mode-\(currentMode)"]
        XCTAssertTrue(destination.waitForExistence(timeout: 3))
        attachScreenshot(app, name: "\(currentMode) destination menu in dark device appearance")
        destination.tap()
    }

    @MainActor
    private func assertSettingsDetailBack(_ app: XCUIApplication) {
        let integration = app.buttons["SatoriReaderIntegrationLink"]
        for _ in 0..<4 where !isFullyVisibleSettingsRow(integration, app: app) {
            app.collectionViews.firstMatch.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(isFullyVisibleSettingsRow(integration, app: app))
        integration.tap()
        let detail = app.navigationBars["Satori Reader"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        let back = detail.buttons.firstMatch
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(integration.waitForExistence(timeout: 5))
        XCTAssertFalse(detail.exists)
        XCTAssertFalse(app.navigationBars.buttons["Back"].exists)
    }

    @MainActor
    private func isFullyVisibleSettingsRow(_ row: XCUIElement, app: XCUIApplication) -> Bool {
        guard row.exists, row.isHittable else { return false }
        // XCTest can consider a few pixels behind the home indicator hittable.
        return row.frame.minY > app.buttons["app-mode-picker"].frame.maxY
            && row.frame.maxY < app.frame.maxY - 60
    }
}
