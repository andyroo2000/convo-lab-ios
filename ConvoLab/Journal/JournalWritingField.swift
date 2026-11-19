import SwiftUI
import UIKit

struct JournalDeviceWritingField: UIViewRepresentable {
    @Environment(\.journalWritingFocus) private var focusChanged
    @Binding var text: String
    var label: String
    var minimumLines = 4
    var autofocus = false
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
        context.coordinator.focusChanged = focusChanged
        view.focusOnAppearance = autofocus
        view.accessibilityLabel = label
        view.setEditingEnabled(enabled)
        view.configure(text: text, font: typography.unscaledFont.withSize(typography.size * scale))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: JournalWritingTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.fittingSize(width: width, minimumLines: minimumLines)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var focusChanged: (CGRect?) -> Void = { _ in }
        init(text: Binding<String>) { self.text = text }

        func textViewDidBeginEditing(_ textView: UITextView) {
            focusChanged(textView.window.map { $0.convert($0.bounds, to: nil) })
        }
        func textViewDidEndEditing(_ textView: UITextView) { focusChanged(nil) }

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

class JournalWritingTextView: UITextView {
    var focusOnAppearance = false
    private var didAutofocus = false
    private var requestedEditingEnabled = true
    private var needsCaretReveal = false
    private let placeholder: UITextView
    private let placeholderStorage: NSTextStorage
    private let notebookStorage: NSTextStorage
    private var writingFont = UIFont.systemFont(ofSize: 20)

    init() {
        let storage = NSTextStorage()
        notebookStorage = storage
        let previewStorage = NSTextStorage()
        placeholderStorage = previewStorage
        placeholder = UITextView(frame: .zero, textContainer: Self.notebookContainer(storage: previewStorage))
        super.init(frame: .zero, textContainer: Self.notebookContainer(storage: storage))
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Use the editor's TextKit metrics, including fixed paragraph height and Japanese font fallback.
        placeholder.backgroundColor = .clear
        placeholder.textContainerInset = .zero
        placeholder.textContainer.lineFragmentPadding = 0
        placeholder.isScrollEnabled = false
        placeholder.isEditable = false
        placeholder.isSelectable = false
        placeholder.isAccessibilityElement = false
        placeholder.accessibilityElementsHidden = true
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

    func setEditingEnabled(_ enabled: Bool) {
        requestedEditingEnabled = enabled
        guard isEditable != enabled else { return }
        // Resigning first responder inside updateUIView reenters SwiftUI's responder graph.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isEditable = self.requestedEditingEnabled
        }
    }

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
        var placeholderAttributes = attributes
        placeholderAttributes[.foregroundColor] = UIColor.placeholderText
        placeholder.attributedText = NSAttributedString(string: "今日は…", attributes: placeholderAttributes)
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

    private func focusIfRequested() {
        guard focusOnAppearance, !didAutofocus, window != nil, isEditable else { return }
        didAutofocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.isEditable else { return }
            self.becomeFirstResponder()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        focusIfRequested()
        revealCaret()
        placeholder.frame = CGRect(origin: .zero, size: bounds.size)
    }
}
