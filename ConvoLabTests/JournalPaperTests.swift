import CoreText
import SwiftUI
import XCTest
@testable import ConvoLab

@MainActor
final class JournalPaperTests: XCTestCase {
    func testJapaneseNotebookDateAndInvalidFallback() {
        XCTAssertEqual(JournalDates.notebook("2026-11-12"), "2026年11月12日（木）")
        XCTAssertEqual(JournalDates.notebook("2024-02-29"), "2024年2月29日（木）")
        XCTAssertEqual(JournalDates.notebook("2026-02-30"), "2026-02-30")
        XCTAssertEqual(JournalDates.notebook("invalid"), "invalid")
        XCTAssertEqual(UIFont(name: "Yomogi-Regular", size: 17)?.fontName, "Yomogi-Regular")
    }

    func testPaperSpacingPreservesOriginalTextFontAndFurigana() {
        let font = JournalTypography(size: 26).unscaledFont
        let source = StudyRubyDocument.parse("映画[えいが]を見ました。", knownKanji: [])
            .attributedString(pointSize: 26, weight: .regular, color: .label, alignment: .left, font: font)
        let text = NSMutableAttributedString(attributedString: source)
        JournalPaperText.align(text, font: font)
        XCTAssertEqual(text.string, source.string)
        XCTAssertEqual(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont, font)
        XCTAssertNotNil(text.attribute(NSAttributedString.Key(kCTRubyAnnotationAttributeName as String), at: 0, effectiveRange: nil))
        let paragraph = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(paragraph?.minimumLineHeight, 70.2)
        XCTAssertEqual(paragraph?.maximumLineHeight, 70.2)
        XCTAssertEqual(paragraph?.lineSpacing, 0)
        XCTAssertEqual(paragraph?.lineBreakMode, .byWordWrapping)
    }

    func testTearsStayWithinTheSheetAtNarrowAndWideSizes() {
        for width: CGFloat in [240, 700] {
            let rect = CGRect(x: 0, y: 0, width: width, height: 400)
            for tornTop in [false, true] {
                let path = JournalPaperEdge(tornTop: tornTop).path(in: rect)
                XCTAssertTrue(rect.contains(path.boundingRect))
                XCTAssertTrue(path.contains(CGPoint(x: width / 2, y: 200)))
                XCTAssertFalse(path.contains(CGPoint(x: width / 2, y: 400)))
            }
        }
    }
}
