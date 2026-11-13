import XCTest
@testable import ConvoLab

@MainActor
final class JournalHighlightLayoutTests: XCTestCase {
    func testWrappedHighlightsLeaveSpaceBetweenRowsAndClearWhenRemoved() {
        let view = JournalHighlightTextView()
        XCTAssertNotNil(view.textLayoutManager)
        view.frame = CGRect(x: 0, y: 0, width: 160, height: 400)
        view.isScrollEnabled = false
        let segment = JournalSegment(text: "映画を見た。映画を見た。映画を見た。", reading: "映画[えいが]を見[み]た。映画[えいが]を見[み]た。映画[えいが]を見[み]た。", kind: .optional, suggestion: nil, suggestionReading: nil, explanation: nil, explanationReading: nil)
        view.attributedText = JournalEditText.attributed(segment, knownKanji: [])
        view.highlights = [(NSRange(location: 0, length: view.attributedText.length), .optional)]
        view.layoutIfNeeded()
        let rectangles = backgroundRects(view)
        XCTAssertGreaterThan(rectangles.count, 1)
        for (previous, next) in zip(rectangles, rectangles.dropFirst()) {
            XCTAssertLessThan(previous.maxY, next.minY, "Highlight rectangles: \(rectangles)")
        }
        XCTAssertTrue(rectangles.allSatisfy { view.bounds.contains($0) })
        view.frame.size.height = 40
        view.layoutIfNeeded()
        XCTAssertTrue(backgroundRects(view).allSatisfy { view.bounds.contains($0) })
        view.highlights = []
        view.layoutIfNeeded()
        XCTAssertTrue(backgroundRects(view).isEmpty)
    }

    func testOutOfDateRangesDoNotDrawOutsideTheDocument() {
        let view = JournalHighlightTextView()
        view.frame = CGRect(x: 0, y: 0, width: 160, height: 200)
        view.attributedText = NSAttributedString(string: "映画")
        view.highlights = [(NSRange(location: 0, length: 100), .correction)]
        view.layoutIfNeeded()
        XCTAssertTrue(backgroundRects(view).isEmpty)
    }

    private func backgroundRects(_ view: JournalHighlightTextView) -> [CGRect] {
        (view.layer.sublayers ?? []).compactMap { ($0 as? CAShapeLayer)?.path?.boundingBoxOfPath }
            .filter { $0.height > 1 }.sorted { $0.minY < $1.minY }
    }
}
