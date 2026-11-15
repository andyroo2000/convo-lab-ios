import XCTest
import UIKit
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

    func testHighlightsCoverGlyphRowsAcrossJournalFontsAndSizes() throws {
        for family in ["sans", "serif"] {
            for size in [16.0, 20.0, 30.0] {
                try assertGlyphCoverage(font: JournalTypography(font: family, size: size).unscaledFont)
            }
        }
    }

    private func assertGlyphCoverage(font: UIFont) throws {
        let view = JournalHighlightTextView()
        view.frame = CGRect(x: 0, y: 0, width: 180, height: 800)
        view.textContainerInset = UIEdgeInsets(top: 17, left: 9, bottom: 0, right: 9)
        let segment = JournalSegment(text: "", reading: "先々日の夜は辺りしい映画を見た。映画[えいが]を見[み]た。\n車で運転するながら。", kind: .correction, suggestion: nil, suggestionReading: nil, explanation: nil, explanationReading: nil)
        view.attributedText = JournalEditText.attributed(segment, knownKanji: [], font: font)
        view.highlights = [(NSRange(location: 0, length: view.attributedText.length), .correction)]
        view.layoutIfNeeded()
        let rectangles = backgroundRects(view)
        let manager = try XCTUnwrap(view.textLayoutManager)
        var rowCount = 0
        manager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            for line in fragment.textLineFragments where line.characterRange.length > 0 {
                let baseline = view.textContainerInset.top + fragment.layoutFragmentFrame.minY
                    + line.typographicBounds.minY + line.glyphOrigin.y
                // The entire base-font ascent/descent must be covered, not merely
                // the lower half of the characters and the following line spacing.
                let matching = rectangles.filter { $0.minY <= baseline - font.ascender + 0.5
                    && $0.maxY >= baseline - font.descender - 0.5 }
                XCTAssertFalse(matching.isEmpty, "Missing glyph coverage for \(font.fontName) at \(font.pointSize), baseline \(baseline): \(rectangles)")
                rowCount += 1
            }
            return true
        }
        XCTAssertGreaterThan(rowCount, 2)
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
