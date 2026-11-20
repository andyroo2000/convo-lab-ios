import SwiftUI
import UIKit

struct JournalExplanationText: UIViewRepresentable {
    @Environment(\.journalTypography) private var typography
    let segment: JournalSegment
    let knownKanji: Set<Character>

    func makeCoordinator() -> JournalExplanationLayout { JournalExplanationLayout() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.adjustsFontForContentSizeCategory = true
        view.isEditable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        // Ruby readings extend above the first baseline; reserve space for their ascenders.
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 2, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.textLayoutManager?.usesFontLeading = false
        view.textLayoutManager?.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let size = max(14, typography.size - 4)
        let font = UIFontMetrics.default.scaledFont(for: UIFont(name: "CrimsonPro-Regular", size: size) ?? .systemFont(ofSize: size))
        let content = JournalExplanationContent.attributed(segment, knownKanji: knownKanji, font: font)
        context.coordinator.update(content, font: font)
        view.attributedText = content
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: measured.height)
    }
}

// Interpret only emphasis. Links and HTML remain inert text.
enum JournalExplanationContent {
    static func text(_ segment: JournalSegment) -> String {
        var result = sentenceSpacing(segment.explanationReading ?? segment.explanation ?? "")
        guard segment.replacement != nil else { return result }
        let shown = StudyRubyDocument.parse(segment.reading + " " + (segment.replacementReading ?? ""), knownKanji: [])
        for case let .ruby(base, reading) in shown.segments {
            result = result.replacingOccurrences(of: "\(base)[\(reading)]", with: base)
        }
        return result
    }

    private static func sentenceSpacing(_ text: String) -> String {
        // Breakable half-em gaps scale with the font; leave paragraphs and ordinary spaces intact.
        let patterns = [
            #"((?:[\p{Han}\p{Hiragana}\p{Katakana}々〆ー]|\[[ぁ-ゖァ-ヺー]+\])\*{0,3}[.!?]["'’”)]?\*{0,3})[ \t]+(?=\S)"#,
            #"([.!?]["'’”)]?\*{0,3})[ \t]+(?=\*{0,3}["'‘“(「『]?[\p{Han}\p{Hiragana}\p{Katakana}])"#
        ]
        return patterns.reduce(text) { value, pattern in
            value.replacingOccurrences(of: pattern, with: "$1\u{2002}", options: .regularExpression)
        }
    }

    static func attributed(_ segment: JournalSegment, knownKanji: Set<Character>, font: UIFont) -> NSAttributedString {
        let document = StudyRubyDocument.parse(text(segment), knownKanji: knownKanji)
        let latin = font.withSize(font.pointSize * JournalCorrectionFonts.latinScale)
        let result = NSMutableAttributedString(attributedString: document.attributedString(pointSize: font.pointSize,
            weight: .regular, color: JournalPopoverStyle.ink, alignment: .left, extraLineSpacing: 4, font: latin))
        JournalCorrectionFonts.applyJapanese(to: result, size: font.pointSize)
        colorReplacement(result, replacement: segment.replacement ?? "")
        emphasize(result, font: latin)
        // Use one baseline pitch even when Japanese fallback fonts have taller metrics.
        let paragraph = NSMutableParagraphStyle()
        let japanese = JournalCorrectionFonts.japanese(size: font.pointSize)
        let pitch = max(font.lineHeight, japanese.lineHeight) + font.pointSize * (document.hasRuby ? 0.5 : 0.15)
        paragraph.minimumLineHeight = pitch
        paragraph.maximumLineHeight = pitch
        paragraph.lineBreakStrategy = []
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        JournalRubyTypography.compact(result)
        return result
    }

    private static func colorReplacement(_ text: NSMutableAttributedString, replacement: String) {
        for match in JournalCorrectionFonts.words(in: text) {
            let term = (text.string as NSString).substring(with: match.range)
            if term == replacement {
                text.addAttribute(.foregroundColor, value: UIColor(red: 0.239, green: 0.412, blue: 0.298, alpha: 1), range: match.range)
            }
        }
    }

    private static func emphasize(_ text: NSMutableAttributedString, font: UIFont) {
        guard let expression = try? NSRegularExpression(pattern: #"(?<!\*)(\*{1,3})([^*]+)\1(?!\*)"#) else { return }
        let matches = expression.matches(in: text.string, range: NSRange(location: 0, length: text.length))
        for match in matches.reversed() {
            let count = match.range(at: 1).length
            let content = match.range(at: 2)
            applyEmphasis(text, range: content, count: count, font: font)
            text.deleteCharacters(in: NSRange(location: NSMaxRange(content), length: count))
            text.deleteCharacters(in: match.range(at: 1))
        }
    }

    private static func applyEmphasis(_ text: NSMutableAttributedString, range: NSRange, count: Int, font: UIFont) {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if count >= 2 { traits.insert(.traitBold) }
        if count != 2 { traits.insert(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return }
        text.enumerateAttribute(.font, in: range) { existing, run, _ in
            guard (existing as? UIFont) == font else { return }
            text.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: run)
        }
    }

}
