import SwiftUI
import UIKit

struct JournalWritingField: UIViewRepresentable {
    @Binding var text: String
    var label: String
    var minimumLines = 4
    @Environment(\.journalTypography) private var typography
    @Environment(\.isEnabled) private var enabled
    @ScaledMetric(relativeTo: .body) private var scale = 1.0

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> JournalWritingTextView {
        let view = JournalWritingTextView()
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: JournalWritingTextView, context: Context) {
        context.coordinator.text = $text
        view.accessibilityLabel = label
        view.isEditable = enabled
        view.configure(text: text, font: typography.unscaledFont.withSize(typography.size * scale))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: JournalWritingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.fittingSize(width: width, minimumLines: minimumLines)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? JournalWritingTextView)?.requestCaretReveal()
        }

        func textViewDidChange(_ textView: UITextView) {
            (textView as? JournalWritingTextView)?.requestCaretReveal()
            text.wrappedValue = textView.text
            textView.invalidateIntrinsicContentSize()
            (textView as? JournalWritingTextView)?.updatePlaceholder()
        }
    }
}

final class JournalWritingTextView: UITextView {
    private var needsCaretReveal = false
    private let placeholder = UILabel()
    private let notebookStorage: NSTextStorage
    private var writingFont = UIFont.systemFont(ofSize: 20)

    init() {
        let storage = NSTextStorage()
        notebookStorage = storage
        super.init(frame: .zero, textContainer: Self.notebookContainer(storage: storage))
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        placeholder.text = "今日は…"
        placeholder.textColor = .placeholderText
        placeholder.isAccessibilityElement = false
        placeholder.isUserInteractionEnabled = false
        addSubview(placeholder)
    }

    private static func notebookContainer(storage: NSTextStorage) -> NSTextContainer {
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        let layout = NSLayoutManager()
        // Hiragino fonts include leading beyond the paragraph height; the paper already supplies it.
        layout.usesFontLeading = false
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        return container
    }

    required init?(coder: NSCoder) { nil }

    func configure(text: String, font: UIFont) {
        // Never replace marked text or reset the selection during Japanese composition.
        guard markedTextRange == nil else { return }
        let needsStyle = writingFont != font || attributedText.length == 0
        writingFont = font
        let style = NSMutableAttributedString(string: " ",
            attributes: [.font: font, .foregroundColor: JournalPopoverStyle.ink])
        JournalPaperText.align(style, font: font)
        let attributes = style.attributes(at: 0, effectiveRange: nil)
        if !(self.text as NSString).isEqual(to: text) || needsStyle {
            let selection = selectedRange
            attributedText = NSAttributedString(string: text, attributes: attributes)
            let start = min(selection.location, (text as NSString).length)
            selectedRange = NSRange(location: start, length: min(selection.length, (text as NSString).length - start))
            invalidateIntrinsicContentSize()
        }
        typingAttributes = attributes
        placeholder.font = font
        updatePlaceholder()
    }

    func fittingSize(width: CGFloat, minimumLines: Int) -> CGSize {
        let measured = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let minimumHeight = writingFont.pointSize * JournalPaperText.linePitch * CGFloat(minimumLines)
        return CGSize(width: width, height: max(minimumHeight, ceil(measured.height)))
    }

    func updatePlaceholder() {
        placeholder.isHidden = !text.isEmpty
        setNeedsLayout()
    }

    func requestCaretReveal() {
        needsCaretReveal = true
        setNeedsLayout()
    }

    private func revealCaret() {
        guard needsCaretReveal else { return }
        needsCaretReveal = false
        guard isFirstResponder, let selection = selectedTextRange else { return }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView, scroll.isScrollEnabled {
                let caret = caretRect(for: selection.end).insetBy(dx: 0, dy: -12)
                scroll.scrollRectToVisible(convert(caret, to: scroll), animated: false)
                return
            }
            ancestor = view.superview
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        revealCaret()
        let pitch = writingFont.pointSize * JournalPaperText.linePitch
        placeholder.frame = CGRect(x: 0, y: (pitch - writingFont.lineHeight) / 2,
                                   width: bounds.width, height: writingFont.lineHeight)
    }
}
