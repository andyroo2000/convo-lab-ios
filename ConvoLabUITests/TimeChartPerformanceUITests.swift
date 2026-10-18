import XCTest

final class TimeChartPerformanceUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testWeekSwipesRemainResponsiveAndPreserveNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "time-chart"]
        app.launch()
        let anchor = app.staticTexts["TimeChartFixtureAnchor"]
        XCTAssertTrue(anchor.waitForExistence(timeout: 8))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "loading"), object: anchor)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        let original = anchor.label
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let date = try XCTUnwrap(formatter.date(from: original))
        let previous = formatter.string(from: try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -7, to: date)))

        app.buttons["Start measurement"].tap()
        var historical = date
        for _ in 0..<3 {
            historical = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -7, to: historical))
            dragChart(app, right: true)
            waitForAnchor(formatter.string(from: historical), element: anchor)
        }
        try finishMeasurement(app, phase: "previous-week-sequence")
        app.segmentedControls.buttons["Month"].tap()
        waitForAnchor(original, element: anchor)
        app.segmentedControls.buttons["Week"].tap()

        app.buttons["Start measurement"].tap()
        for _ in 0..<3 {
            dragChart(app, right: true)
            waitForAnchor(previous, element: anchor)
            dragChart(app, right: false)
            waitForAnchor(original, element: anchor)
        }
        try finishMeasurement(app, phase: "adjacent-week-round-trips")
        try assertCategoryFiltering(app, anchor: anchor)
        XCTAssertTrue(app.segmentedControls.buttons["Month"].isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Time chart after repeated swipes"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testUncachedSwipeCanBeCancelledByChangingRange() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixture", "time-chart"]
        app.launch()
        let anchor = app.staticTexts["TimeChartFixtureAnchor"]
        XCTAssertTrue(anchor.waitForExistence(timeout: 8))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "loading"), object: anchor)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        let original = anchor.label
        app.buttons["Uncached"].tap()
        let historical = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", original), object: anchor)
        XCTAssertEqual(XCTWaiter.wait(for: [historical], timeout: 10), .completed)
        app.buttons["Start measurement"].tap()
        dragChart(app, right: true)
        let loading = app.activityIndicators["StudyTimeAnalyticsLoading"]
        XCTAssertTrue(loading.waitForExistence(timeout: 3))
        app.segmentedControls.buttons["Month"].tap()
        waitForAnchor(original, element: anchor)
        XCTAssertTrue(loading.waitForNonExistence(timeout: 3))
        let staleNavigation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", original), object: anchor
        )
        staleNavigation.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [staleNavigation], timeout: 9), .completed)
        app.segmentedControls.buttons["Week"].tap()
        waitForAnchor(original, element: anchor)
        try finishMeasurement(app, phase: "cancel-uncached-week")
    }

    @MainActor
    private func assertCategoryFiltering(_ app: XCUIApplication, anchor: XCUIElement) throws {
        let totals = try XCTUnwrap(anchor.value as? String).split(separator: "|").map(String.init)
        XCTAssertEqual(totals.count, 2)
        XCTAssertTrue(app.staticTexts[totals[0]].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "Card review").count, 1)
        let review = app.buttons["Card review"]
        XCTAssertTrue(review.isHittable, app.debugDescription)
        review.doubleTap()
        XCTAssertTrue(app.staticTexts[totals[1]].waitForExistence(timeout: 3))
        XCTAssertTrue((review.value as? String)?.contains("filtered out") == true)
        review.doubleTap()
        XCTAssertTrue(app.staticTexts[totals[0]].waitForExistence(timeout: 3))
        XCTAssertTrue((review.value as? String)?.contains("included") == true)
    }

    @MainActor
    private func dragChart(_ app: XCUIApplication, right: Bool) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.25 : 0.75, dy: 0.42))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.75 : 0.25, dy: 0.42))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
    }

    @MainActor
    private func waitForAnchor(_ expected: String, element: XCUIElement) {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 12), .completed)
    }

    @MainActor
    private func finishMeasurement(_ app: XCUIApplication, phase: String) throws {
        app.buttons["Stop measurement"].tap()
        let value = try XCTUnwrap(app.staticTexts["TimeChartFixtureMetrics"].value as? String)
        var metrics = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
        metrics["phase"] = phase
        XCTAssertGreaterThan(try XCTUnwrap(metrics["heartbeatSamples"] as? Int), 0)
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "time-chart-\(phase).json"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("TIME_CHART_PERFORMANCE_JSON \(String(decoding: data, as: UTF8.self))")
    }
}
