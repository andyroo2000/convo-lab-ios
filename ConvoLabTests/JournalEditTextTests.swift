import CoreText
import Testing
import UIKit
@testable import ConvoLab

@MainActor
struct JournalEditTextTests {
    @Test func replacementKeepsOnlyOriginalWordsAndReadings() {
        let segment = makeSegment()
        let text = JournalEditText.attributed(segment, knownKanji: [])
        #expect(text.string == segment.text)
        #expect(text.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) == nil)
        let ruby = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
        #expect(text.attribute(ruby, at: 0, effectiveRange: nil) != nil)
        #expect(JournalEditText.accessibilityLabel(segment).contains("Replace 映画を見ますた。 with 映画を見ました。"))
    }

    @Test func knownKanjiReadingsStayHiddenInOriginal() {
        let text = JournalEditText.attributed(makeSegment(), knownKanji: ["映", "画", "見"])
        let ruby = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
        #expect(text.attribute(ruby, at: 0, effectiveRange: nil) == nil)
        #expect(text.attribute(ruby, at: 3, effectiveRange: nil) == nil)
    }

    @Test func unchangedAndMissingReplacementsDoNotStrikeOriginal() {
        for segment in [makeSegment(kind: .plain), makeSegment(kind: .keep), makeSegment(replacement: nil)] {
            let text = JournalEditText.attributed(segment, knownKanji: [])
            #expect(text.string == segment.text)
            #expect(text.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) == nil)
            #expect(JournalEditText.accessibilityLabel(segment) == segment.text)
        }
    }

    @Test func deletionsAndOptionalChangesKeepOriginalWords() {
        let deletion = makeSegment(replacement: "", replacementReading: nil)
        let text = JournalEditText.attributed(deletion, knownKanji: [])
        #expect(text.string == deletion.text)
        #expect(text.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) == nil)
        #expect(JournalEditText.accessibilityLabel(deletion).hasPrefix("Remove "))
        let optional = makeSegment(kind: .optional, replacementReading: nil)
        #expect(JournalEditText.attributed(optional, knownKanji: []).string == optional.text)
    }

    @Test func insertionHasVisibleAnchorAndAccessibleUnicodeReplacement() {
        let segment = JournalSegment(text: "", reading: "", kind: .correction, suggestion: "私の友達です。", suggestionReading: nil, explanation: nil, explanationReading: nil, replacement: "🙂\n友達", replacementReading: "🙂\n友達[ともだち]")
        let text = JournalEditText.attributed(segment, knownKanji: [])
        #expect(text.string == "＋")
        #expect(text.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) == nil)
        #expect(JournalEditText.accessibilityLabel(segment) == "Insert 🙂\n友達. ")
    }

    @Test func decodesExactPhraseWithoutRepeatingSentenceContext() throws {
        let json = #"{"text":"辺りしい","reading":"辺りしい","kind":"correction","suggestion":"先々日の夜は新しい映画を見た。","suggestionReading":"先々日[さきおととい]の夜[よる]は新[あたら]しい映画[えいが]を見[み]た。","replacement":"新しい","replacementReading":"新[あたら]しい"}"#
        let segment = try JSONDecoder().decode(JournalSegment.self, from: Data(json.utf8))
        #expect(segment.replacement == "新しい")
        #expect(segment.replacementReading == "新[あたら]しい")
        let text = JournalEditText.attributed(segment, knownKanji: [])
        #expect(text.string == "辺りしい")
        #expect(JournalEditText.accessibilityLabel(segment) == "Replace 辺りしい with 新しい. ")
    }

    @Test func legacyFeedbackWithoutReplacementNeverInsertsFullSentence() throws {
        let json = #"{"text":"見ますた","reading":"見[み]ますた","kind":"correction","suggestion":"昨日は映画を見ました。"}"#
        let segment = try JSONDecoder().decode(JournalSegment.self, from: Data(json.utf8))
        #expect(segment.replacement == nil)
        let text = JournalEditText.attributed(segment, knownKanji: [])
        #expect(text.string == "見ますた")
        #expect(text.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) == nil)
        #expect(JournalEditText.accessibilityLabel(segment) == "見ますた")
    }

    private func makeSegment(kind: JournalSegment.Kind = .correction, replacement: String? = "映画を見ました。", replacementReading: String? = "映画[えいが]を見[み]ました。") -> JournalSegment {
        JournalSegment(text: "映画を見ますた。", reading: "映画[えいが]を見[み]ますた。", kind: kind, suggestion: "昨日は映画を見ました。", suggestionReading: "昨日[きのう]は映画[えいが]を見[み]ました。", explanation: nil, explanationReading: nil, replacement: replacement, replacementReading: replacementReading)
    }
}
