import SwiftUI
import UIKit

struct JournalCorrectionPassage: UIViewRepresentable {
    let text: String
    let original: Bool
    let knownKanji: Set<Character>

    func makeCoordinator() -> StudyRubyLineBreakDelegate { StudyRubyLineBreakDelegate() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textLayoutManager?.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let font = UIFontMetrics.default.scaledFont(for: UIFont(name: "HiraMinProN-W3", size: 17) ?? .systemFont(ofSize: 17))
        let document = StudyRubyDocument.parse(text, knownKanji: knownKanji)
        let value = NSMutableAttributedString(attributedString: document.attributedString(pointSize: font.pointSize,
            weight: .regular, color: original ? JournalPopoverStyle.ink : .systemGreen, alignment: .left, extraLineSpacing: 4, font: font))
        if original {
            value.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: UIColor.systemRed],
                                range: NSRange(location: 0, length: value.length))
        }
        context.coordinator.updateRubyRanges(in: value)
        view.attributedText = value
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
