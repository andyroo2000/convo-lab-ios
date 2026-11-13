import CoreText
import Testing
import UIKit
@testable import ConvoLab

@MainActor
struct JournalEditTextTests {
    @Test func replacementKeepsBothReadingsAndMarksOnlyChangedText() {
        let segment = makeSegment()
        let text = JournalEditText.attributed(segment, knownKanji: [])
        #expect(text.string == "映画を見ますた。映画を見ました。")
        #expect(text.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        let replacementStart = (segment.text as NSString).length
        #expect(text.attribute(.strikethroughStyle, at: replacementStart, effectiveRange: nil) == nil)
        #expect(text.attribute(.backgroundColor, at: replacementStart, effectiveRange: nil) != nil)
        let ruby = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
        #expect(text.attribute(ruby, at: 0, effectiveRange: nil) != nil)
        #expect(text.attribute(ruby, at: replacementStart, effectiveRange: nil) != nil)
        #expect(JournalEditText.accessibilityLabel(segment).contains("Replace 映画を見ますた。 with 映画を見ました。"))
    }

    @Test func knownKanjiReadingsStayHiddenInBothVersions() {
        let text = JournalEditText.attributed(makeSegment(), knownKanji: ["映", "画", "見"])
        let ruby = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
        #expect(text.attribute(ruby, at: 0, effectiveRange: nil) == nil)
        #expect(text.attribute(ruby, at: 9, effectiveRange: nil) == nil)
    }

    @Test func unchangedAndMissingSuggestionsDoNotStrikeOriginal() {
        for segment in [makeSegment(kind: .plain), makeSegment(kind: .keep), makeSegment(suggestion: nil)] {
            let text = JournalEditText.attributed(segment, knownKanji: [])
            #expect(text.string == segment.text)
            #expect(text.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) == nil)
            #expect(JournalEditText.accessibilityLabel(segment) == segment.text)
        }
    }

    @Test func emptyReplacementIsDeletionAndMissingReadingFallsBackToText() {
        let deletion = makeSegment(suggestion: "", suggestionReading: nil)
        let text = JournalEditText.attributed(deletion, knownKanji: [])
        #expect(text.string == deletion.text)
        #expect(text.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) != nil)
        #expect(JournalEditText.accessibilityLabel(deletion).hasPrefix("Remove "))
        let optional = makeSegment(kind: .optional, suggestionReading: nil)
        #expect(JournalEditText.attributed(optional, knownKanji: []).string == optional.text + (optional.suggestion ?? ""))
    }

    @Test func insertionHasNoRemovedTextAndPreservesUnicodeAndNewlines() {
        let segment = JournalSegment(text: "", reading: "", kind: .correction, suggestion: "🙂\n友達", suggestionReading: "🙂\n友達[ともだち]", explanation: nil, explanationReading: nil)
        let text = JournalEditText.attributed(segment, knownKanji: [])
        #expect(text.string == "🙂\n友達")
        #expect(text.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) == nil)
        #expect(JournalEditText.accessibilityLabel(segment) == "Insert 🙂\n友達. ")
    }

    private func makeSegment(kind: JournalSegment.Kind = .correction, suggestion: String? = "映画を見ました。", suggestionReading: String? = "映画[えいが]を見[み]ました。") -> JournalSegment {
        JournalSegment(text: "映画を見ますた。", reading: "映画[えいが]を見[み]ますた。", kind: kind, suggestion: suggestion, suggestionReading: suggestionReading, explanation: nil, explanationReading: nil)
    }
}
