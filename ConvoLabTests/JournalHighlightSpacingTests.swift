import XCTest
import UIKit
@testable import ConvoLab

@MainActor
final class JournalHighlightSpacingTests: XCTestCase {
    func testAdjacentCorrectionsLeaveSixPointsOfPaper() {
        let first = fragment(source: 0, x: 0)
        let second = fragment(source: 1, x: 80)
        let pair = [first, second]
        let left = first.paintedRect(among: pair)
        let right = second.paintedRect(among: pair)
        XCTAssertEqual(right.minX - left.maxX, 6, accuracy: 0.01)
        XCTAssertEqual(left.minX, -1)
        XCTAssertEqual(right.maxX, 161)
    }

    func testWrappedAndSeparatedFragmentsKeepNormalPadding() {
        let first = fragment(source: 0, x: 0)
        for other in [fragment(source: 0, x: 80), fragment(source: 1, x: 80, y: 90), fragment(source: 1, x: 100)] {
            XCTAssertEqual(first.paintedRect(among: [first, other]), CGRect(x: -1, y: 0, width: 82, height: 30))
        }
    }

    func testNarrowCorrectionsKeepPositiveWidth() {
        let first = fragment(source: 0, x: 0, width: 2)
        let second = fragment(source: 1, x: 2, width: 2)
        XCTAssertGreaterThan(first.paintedRect(among: [first, second]).width, 0)
    }

    private func fragment(source: Int, x: CGFloat, y: CGFloat = 0, width: CGFloat = 80) -> JournalHighlightFragment {
        JournalHighlightFragment(source: source, rect: CGRect(x: x, y: y, width: width, height: 30), optional: false)
    }
}
