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
        view.textLayoutManager?.usesFontLeading = false
        view.textLayoutManager?.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // The selected green needs large bold lettering, including Insert/Remove labels.
        let size = max(19, UIFontMetrics.default.scaledValue(for: typography.size - 2))
        let font = JournalCorrectionFonts.japanese(size: size)
        let latin = font
        let document = StudyRubyDocument.parse(text, knownKanji: knownKanji)
        let value = NSMutableAttributedString(attributedString: document.attributedString(pointSize: font.pointSize,
            weight: .regular, color: original ? JournalPopoverStyle.editOriginal : JournalPopoverStyle.editReplacement, alignment: .left, extraLineSpacing: 2, font: latin))
        if let replacement {
            let arrowRange = NSRange(location: value.length + 1, length: 1)
            let corrected = StudyRubyDocument.parse(" → " + replacement, knownKanji: knownKanji)
            value.append(corrected.attributedString(pointSize: font.pointSize, weight: .regular,
                color: JournalPopoverStyle.editReplacement,
                alignment: .left, extraLineSpacing: 2, font: latin))
            let arrowFont = UIFont(name: "Georgia-Bold", size: font.pointSize) ?? .boldSystemFont(ofSize: font.pointSize)
            value.addAttribute(.font, value: arrowFont, range: arrowRange)
        }
        JournalCorrectionFonts.applyJapanese(to: value, size: font.pointSize)
        JournalRubyTypography.compact(value, useTextColor: true)
        context.coordinator.updateRubyRanges(in: value)
        view.attributedText = value
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: measured.height)
    }
}
