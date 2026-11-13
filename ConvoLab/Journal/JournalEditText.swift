import UIKit

enum JournalEditText {
    static func attributed(_ segment: JournalSegment, knownKanji: Set<Character>) -> NSAttributedString {
        let original = text(segment.reading, knownKanji: knownKanji)
        guard segment.kind.isHighlighted, let replacement = segment.suggestion else { return original }
        original.addAttributes([
            .foregroundColor: UIColor.secondaryLabel,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: UIColor.secondaryLabel
        ], range: NSRange(location: 0, length: original.length))
        let inserted = text(segment.suggestionReading ?? replacement, knownKanji: knownKanji)
        inserted.addAttributes([
            .backgroundColor: UIColor.systemGreen.withAlphaComponent(0.16),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: UIColor.systemGreen
        ], range: NSRange(location: 0, length: inserted.length))
        original.append(inserted)
        return original
    }

    static func accessibilityLabel(_ segment: JournalSegment) -> String {
        guard segment.kind.isHighlighted, let replacement = segment.suggestion else { return segment.text }
        if replacement.isEmpty { return "Remove \(segment.text). " }
        if segment.text.isEmpty { return "Insert \(replacement). " }
        return "Replace \(segment.text) with \(replacement). "
    }

    private static func text(_ reading: String, knownKanji: Set<Character>) -> NSMutableAttributedString {
        NSMutableAttributedString(attributedString: StudyRubyDocument.parse(reading, knownKanji: knownKanji)
            .attributedString(pointSize: 20, weight: .regular, color: .label, alignment: .left, extraLineSpacing: 10))
    }
}
