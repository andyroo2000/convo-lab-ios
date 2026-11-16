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

    private func example(_ explanation: String) -> JournalSegment {
        JournalSegment(text: "", reading: "", kind: .correction, suggestion: nil,
                       suggestionReading: nil, explanation: explanation, explanationReading: nil)
    }
}
