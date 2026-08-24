import XCTest
@testable import ConvoLab

final class StudyMasterySpreadViewTests: XCTestCase {
    func testEntriesPreserveProgressionOrderAndCalculateShares() {
        let spread = StudyMasterySpread(
            apprentice: 42,
            guru: 54,
            master: 33,
            enlightened: 16,
            burned: 5
        )

        XCTAssertEqual(spread.total, 150)
        XCTAssertEqual(spread.entries.map(\.level), StudyMasteryLevel.allCases)
        XCTAssertEqual(spread.entries.map(\.count), [42, 54, 33, 16, 5])
        XCTAssertEqual(spread.entries.map(\.percentage), [28, 36, 22, 11, 3])
    }

    func testEmptySpreadProducesZeroShares() {
        let spread = StudyMasterySpread(
            apprentice: 0,
            guru: 0,
            master: 0,
            enlightened: 0,
            burned: 0
        )

        XCTAssertEqual(spread.total, 0)
        XCTAssertEqual(spread.entries.map(\.share), [0, 0, 0, 0, 0])
    }

    func testNegativeProviderCountsCannotCreateInvalidChartWidths() {
        let spread = StudyMasterySpread(
            apprentice: -1,
            guru: 4,
            master: 0,
            enlightened: 0,
            burned: 0
        )

        XCTAssertEqual(spread.total, 4)
        XCTAssertEqual(spread.entries.map(\.count), [0, 4, 0, 0, 0])
        XCTAssertEqual(spread.entries.map(\.percentage), [0, 100, 0, 0, 0])
    }
}
