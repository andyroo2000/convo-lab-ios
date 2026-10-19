import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeRangeSelectionTests: XCTestCase {
    func testSameRangeRestorationDoesNotSuppressTheNextPickerChange() {
        var selected = StudyTimeRange.week
        var suppressNextReset = false

        StudyTimeRangeSelection.assign(.week, selected: &selected, suppressNextReset: &suppressNextReset)

        XCTAssertEqual(selected, .week)
        XCTAssertFalse(suppressNextReset, "A no-op fallback must not consume the next user selection")
    }

    func testCompletedSelectionDoesNotRearmSuppressionAfterItsChangeWasConsumed() {
        var selected = StudyTimeRange.month
        var suppressNextReset = false
        StudyTimeRangeSelection.assign(.week, selected: &selected, suppressNextReset: &suppressNextReset)
        XCTAssertEqual(selected, .week)
        XCTAssertTrue(suppressNextReset)

        // SwiftUI's onChange consumes the programmatic transition once.
        suppressNextReset = false
        StudyTimeRangeSelection.assign(.week, selected: &selected, suppressNextReset: &suppressNextReset)

        XCTAssertFalse(suppressNextReset, "Completing an already selected target must leave the picker responsive")
    }

    func testNoOpDoesNotClearSuppressionForAnUnconsumedRealTransition() {
        var selected = StudyTimeRange.month
        var suppressNextReset = false
        StudyTimeRangeSelection.assign(.week, selected: &selected, suppressNextReset: &suppressNextReset)

        StudyTimeRangeSelection.assign(nil, selected: &selected, suppressNextReset: &suppressNextReset)
        StudyTimeRangeSelection.assign(.week, selected: &selected, suppressNextReset: &suppressNextReset)

        XCTAssertEqual(selected, .week)
        XCTAssertTrue(suppressNextReset, "The actual range change still needs its one onChange exemption")
    }
}
