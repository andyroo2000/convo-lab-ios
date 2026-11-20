import XCTest
import UIKit
@testable import ConvoLab

final class JournalExplanationTests: XCTestCase {
    @MainActor
    func testOnlyEmphasisIsInterpretedAndMarkupRemainsInert() {
        let segment = example("Use **past tense**, *here*. <b>literal</b> [link](https://example.com)")
        let text = JournalExplanationContent.attributed(segment, knownKanji: [], font: .systemFont(ofSize: 16))
        XCTAssertEqual(text.string, "Use past tense, here. <b>literal</b> [link](https://example.com)")
        XCTAssertNil(text.attribute(.link, at: 0, effectiveRange: nil))
        let bold = text.attribute(.font, at: 4, effectiveRange: nil) as? UIFont
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    }

    @MainActor
    func testRepeatedReadingIsOmittedButDifferentReadingRemains() {
        var segment = example("日[ひ] and 日[にち]")
        segment.replacement = "日"
        segment.replacementReading = "日[ひ]"
        XCTAssertEqual(JournalExplanationContent.text(segment), "日 and 日[にち]")
    }

    @MainActor
    func testOnlyExactReplacementTermsAreGreen() {
        var segment = example("映画 and 見ました and 見ましたね. **見ました**")
        segment.replacement = "見ました"
        let text = JournalExplanationContent.attributed(segment, knownKanji: [], font: .systemFont(ofSize: 16))
        let plain = text.string as NSString
        let green = UIColor(red: 0.239, green: 0.412, blue: 0.298, alpha: 1)
        for term in ["映画", "見ましたね"] {
            XCTAssertEqual(text.attribute(.foregroundColor, at: plain.range(of: term).location, effectiveRange: nil) as? UIColor, JournalPopoverStyle.ink)
        }
        XCTAssertEqual(text.attribute(.foregroundColor, at: plain.range(of: "見ました").location, effectiveRange: nil) as? UIColor, green)
        segment.replacement = "映画を見ました。"
        let sentence = JournalExplanationContent.attributed(segment, knownKanji: [], font: .systemFont(ofSize: 16))
        XCTAssertEqual(sentence.attribute(.foregroundColor, at: plain.range(of: "見ました").location, effectiveRange: nil) as? UIColor, JournalPopoverStyle.ink)
    }

    @MainActor
    func testEmphasisDoesNotJoinJapaneseTermsOrChangeTheirFont() {
        var segment = example("見**ま**した and **見ました**")
        segment.replacement = "見ました"
        let text = JournalExplanationContent.attributed(segment, knownKanji: [], font: .systemFont(ofSize: 16))
        XCTAssertEqual(text.string, "見ました and 見ました")
        XCTAssertEqual(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, JournalPopoverStyle.ink)
        let finalTerm = (text.string as NSString).range(of: "見ました", options: .backwards)
        XCTAssertEqual(text.attribute(.foregroundColor, at: finalTerm.location, effectiveRange: nil) as? UIColor,
                       UIColor(red: 0.239, green: 0.412, blue: 0.298, alpha: 1))
        let japanese = text.attribute(.font, at: finalTerm.location, effectiveRange: nil) as? UIFont
        XCTAssertEqual(japanese?.fontName, "HiraMinProN-W6")
        XCTAssertEqual(japanese?.pointSize, 16)
        let latin = text.attribute(.font, at: (text.string as NSString).range(of: "and").location, effectiveRange: nil) as? UIFont
        XCTAssertEqual(latin?.pointSize ?? 0, 12.8, accuracy: 0.01)
    }

    @MainActor
    func testFullwidthLatinAndNumbersKeepTheEnglishSize() {
        let text = JournalExplanationContent.attributed(example("映画（Ａ１）"), knownKanji: [], font: .systemFont(ofSize: 20))
        let sizes = (0..<text.length).map { (text.attribute(.font, at: $0, effectiveRange: nil) as? UIFont)?.pointSize }
        XCTAssertEqual(sizes, [20, 20, 20, 16, 16, 20])
    }

    @MainActor
    func testMixedLanguageSentenceSpacingPreservesEnglishAndNewlines() {
        let segment = example("Use 日本[にほん]. Next. **早め**. Another. 日本語.\nEnglish. English.")
        XCTAssertEqual(JournalExplanationContent.text(segment), "Use 日本[にほん].\u{2002}Next.\u{2002}**早め**.\u{2002}Another.\u{2002}日本語.\nEnglish. English.")
    }

    @MainActor
    func testMixedSentenceBoundariesMatchWebAndDoNotChangeStoredText() {
        let cases = [
            ("Use とても to describe how tired you were. たくさん expresses quantity.",
             "Use とても to describe how tired you were.\u{2002}たくさん expresses quantity."),
            ("Tired? **とても** fits! **疲れた** means tired.", "Tired?\u{2002}**とても** fits!\u{2002}**疲れた** means tired."),
            ("Try it. “とても” fits.", "Try it.\u{2002}“とても” fits."),
            ("**日本.** Another sentence.", "**日本.**\u{2002}Another sentence."),
            ("Use 日本!” Next.", "Use 日本!”\u{2002}Next."),
            ("English.\u{2002}日本語.\u{2002}Next.", "English.\u{2002}日本語.\u{2002}Next."),
            ("English.\n日本語", "English.\n日本語"),
            ("Use とても here, then 日本語.", "Use とても here, then 日本語."),
            ("Version 3.14. Visit example.jp. Done.", "Version 3.14. Visit example.jp. Done.")
        ]
        for (input, expected) in cases {
            let segment = example(input)
            XCTAssertEqual(JournalExplanationContent.text(segment), expected, input)
            XCTAssertEqual(segment.explanation, input)
        }
    }

    private func example(_ explanation: String) -> JournalSegment {
        JournalSegment(text: "", reading: "", kind: .correction, suggestion: nil,
                       suggestionReading: nil, explanation: explanation, explanationReading: nil)
    }
}
