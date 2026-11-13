import UIKit

enum JournalEditText {
    static func attributed(_ segment: JournalSegment, knownKanji: Set<Character>, font: UIFont? = nil) -> NSAttributedString {
        // Insertions need a tappable anchor, but never add replacement words to the original.
        let insertion = segment.kind.isHighlighted && segment.text.isEmpty && !(segment.replacement ?? "").isEmpty
        return text(insertion ? "＋" : segment.reading, knownKanji: knownKanji, font: font)
    }

    static func accessibilityLabel(_ segment: JournalSegment) -> String {
        guard segment.kind.isHighlighted, let replacement = segment.replacement else { return segment.text }
        if replacement.isEmpty { return "Remove \(segment.text). " }
        if segment.text.isEmpty { return "Insert \(replacement). " }
        return "Replace \(segment.text) with \(replacement). "
    }

    private static func text(_ reading: String, knownKanji: Set<Character>, font: UIFont?) -> NSMutableAttributedString {
        NSMutableAttributedString(attributedString: StudyRubyDocument.parse(reading, knownKanji: knownKanji)
            .attributedString(pointSize: 20, weight: .regular, color: JournalPopoverStyle.ink, alignment: .left, extraLineSpacing: 12, font: font))
    }
}
