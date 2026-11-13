import CoreText
import XCTest
@testable import ConvoLab

@MainActor
final class JournalTypographyTests: XCTestCase {
    func testInvalidSizesRemainReadable() {
        XCTAssertEqual(JournalTypography(size: .nan).size, 20)
        XCTAssertEqual(JournalTypography(size: 1).size, 16)
        XCTAssertEqual(JournalTypography(size: 99).size, 30)
        XCTAssertFalse(JournalTypography(font: "invalid").serif)
    }

    func testJapaneseFontChoicesAreDistinct() {
        let sans = JournalTypography(font: "sans", size: 24).uiFont
        let serif = JournalTypography(font: "serif", size: 24).uiFont
        XCTAssertNotEqual(sans.fontName, serif.fontName)
        XCTAssertTrue(serif.fontName.contains("Min"))
        XCTAssertEqual(sans.pointSize, serif.pointSize)
    }

    func testVisibleEditsUseChosenFontForBothVersions() {
        let segment = JournalSegment(text: "映画", reading: "映画[えいが]", kind: .correction,
            suggestion: "本", suggestionReading: "本[ほん]", explanation: nil, explanationReading: nil)
        let font = JournalTypography(font: "serif", size: 28).uiFont
        let text = JournalEditText.attributed(segment, knownKanji: [], font: font)
        XCTAssertEqual(text.string, "映画本")
        for index in [0, 2] {
            XCTAssertEqual(text.attribute(.font, at: index, effectiveRange: nil) as? UIFont, font)
            XCTAssertNotNil(text.attribute(NSAttributedString.Key(kCTRubyAnnotationAttributeName as String), at: index, effectiveRange: nil))
        }
        XCTAssertNotNil(text.attribute(.strikethroughStyle, at: 0, effectiveRange: nil))
        XCTAssertNotNil(text.attribute(.underlineStyle, at: 2, effectiveRange: nil))
    }

    func testCustomFontPreservesFurigana() {
        let document = StudyRubyDocument.parse("今日[きょう]は晴れです。", knownKanji: [])
        let font = JournalTypography(font: "serif", size: 28).uiFont
        let text = document.attributedString(pointSize: 28, weight: .regular, color: .label, alignment: .left, font: font)
        XCTAssertEqual(text.string, "今日は晴れです。")
        XCTAssertEqual(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont, font)
        XCTAssertNotNil(text.attribute(NSAttributedString.Key(kCTRubyAnnotationAttributeName as String), at: 0, effectiveRange: nil))
    }
}
