import SwiftUI
import UIKit

struct JournalExplanationText: UIViewRepresentable {
    let segment: JournalSegment
    let knownKanji: Set<Character>

    func makeCoordinator() -> StudyRubyLineBreakDelegate { StudyRubyLineBreakDelegate() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.adjustsFontForContentSizeCategory = true
        view.isEditable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 2, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.textLayoutManager?.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let font = UIFontMetrics.default.scaledFont(for: UIFont(name: "Georgia", size: 16) ?? .systemFont(ofSize: 16))
        let content = JournalExplanationContent.attributed(segment, knownKanji: knownKanji, font: font)
        context.coordinator.updateRubyRanges(in: content)
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
        var result = segment.explanationReading ?? segment.explanation ?? ""
        guard segment.replacement != nil else { return result }
        let shown = StudyRubyDocument.parse(segment.reading + " " + (segment.replacementReading ?? ""), knownKanji: [])
        for case let .ruby(base, reading) in shown.segments {
            result = result.replacingOccurrences(of: "\(base)[\(reading)]", with: base)
        }
        return result
    }

    static func attributed(_ segment: JournalSegment, knownKanji: Set<Character>, font: UIFont) -> NSAttributedString {
        let document = StudyRubyDocument.parse(text(segment), knownKanji: knownKanji)
        let result = NSMutableAttributedString(attributedString: document.attributedString(pointSize: font.pointSize,
            weight: .regular, color: JournalPopoverStyle.ink, alignment: .left, extraLineSpacing: 4, font: font))
        styleJapanese(result, size: font.pointSize, replacement: segment.replacement ?? "")
        emphasize(result, font: font)
        return result
    }

    private static func styleJapanese(_ text: NSMutableAttributedString, size: CGFloat, replacement: String) {
        guard let pattern = try? NSRegularExpression(pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}々〆ー]+"#) else { return }
        let font = UIFont(name: "HiraMinProN-W3", size: size) ?? .systemFont(ofSize: size)
        for match in pattern.matches(in: text.string, range: NSRange(location: 0, length: text.length)) {
            let term = (text.string as NSString).substring(with: match.range)
            let color = term == replacement ? UIColor(red: 0.239, green: 0.412, blue: 0.298, alpha: 1) : JournalPopoverStyle.ink
            text.addAttributes([.font: font, .foregroundColor: color], range: match.range)
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
