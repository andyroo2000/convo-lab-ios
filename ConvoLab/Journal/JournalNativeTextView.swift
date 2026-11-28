import UIKit

final class JournalNativeTextView: JournalWritingTextView {
    let candidates = JournalCandidateBar()
    var hasComposition = false
    var pasteText: ((String) -> Void)?
    var sectionAction: ((String, Int) -> Void)?
    var focusGeometryChanged: ((CGRect) -> Void)?
    private var focusedWindowFrame: CGRect?

    override init() {
        super.init()
        autocorrectionType = .no
        spellCheckingType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        inputAccessoryView = candidates
    }
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard isFirstResponder, let window else { return }
        if traitCollection.userInterfaceIdiom == .pad { candidates.fitWritingWindow(window.bounds.size) }
        let frame = window.convert(window.bounds, to: nil)
        guard frame != focusedWindowFrame else { return }
        focusedWindowFrame = frame
        DispatchQueue.main.async { [weak self] in
            guard let self, isFirstResponder else { return }
            focusGeometryChanged?(frame)
        }
    }

    override func paste(_ sender: Any?) {
        guard let value = UIPasteboard.general.string, let pasteText else { super.paste(sender); return }
        pasteText(value)
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        let height = min(rect.height, (typingAttributes[.font] as? UIFont)?.lineHeight ?? rect.height)
        rect.origin.y += rect.height - height
        rect.size.height = height
        return rect
    }

    override var keyCommands: [UIKeyCommand]? {
        guard hasComposition else { return super.keyCommands }
        return [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow].flatMap { input in
            [UIKeyModifierFlags(), .shift].map { flags in
                let command = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(sectionKey(_:)))
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }
    }

    @objc private func sectionKey(_ command: UIKeyCommand) {
        sectionAction?(command.modifierFlags.contains(.shift) ? "resize" : "focusSection",
                       command.input == UIKeyCommand.inputLeftArrow ? -1 : 1)
    }
}
