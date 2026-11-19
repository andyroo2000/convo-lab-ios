import SwiftUI
import UIKit

struct JournalCorrectionPassage: UIViewRepresentable {
    @Environment(\.journalTypography) private var typography
    let text: String
    let original: Bool
    let knownKanji: Set<Character>
    var replacement: String?

    func makeCoordinator() -> StudyRubyLineBreakDelegate { StudyRubyLineBreakDelegate() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.adjustsFontForContentSizeCategory = true
        view.isEditable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        // Ruby readings extend above the first baseline; reserve space for their ascenders.
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.textLayoutManager?.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let size = max(14, typography.size - 2)
        let font = UIFontMetrics.default.scaledFont(for: UIFont(name: "HiraMinProN-W3", size: size) ?? .systemFont(ofSize: size))
        let document = StudyRubyDocument.parse(text, knownKanji: knownKanji)
        let value = NSMutableAttributedString(attributedString: document.attributedString(pointSize: font.pointSize,
            weight: .regular, color: original ? UIColor(red: 0.537, green: 0.439, blue: 0.392, alpha: 1) : UIColor(red: 0.239, green: 0.412, blue: 0.298, alpha: 1), alignment: .left, extraLineSpacing: 2, font: font))
        if original {
            value.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: UIColor.systemRed],
                                range: NSRange(location: 0, length: value.length))
        }
        if let replacement {
            let corrected = StudyRubyDocument.parse(" → " + replacement, knownKanji: knownKanji)
            value.append(corrected.attributedString(pointSize: font.pointSize, weight: .regular,
                color: UIColor(red: 0.239, green: 0.412, blue: 0.298, alpha: 1),
                alignment: .left, extraLineSpacing: 2, font: font))
        }
        context.coordinator.updateRubyRanges(in: value)
        view.attributedText = value
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: measured.height)
    }
}
