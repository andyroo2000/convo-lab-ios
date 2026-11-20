import SwiftUI
import UIKit

@MainActor
final class JournalTypingCoordinator: NSObject, UITextViewDelegate {
    var text: Binding<String>
    private(set) var composition: JournalNativeComposition?
    var focusChanged: (CGRect?) -> Void = { _ in }
    var unavailable: () -> Void = {}
    private var reportedFailure = false
    private let requests = JournalCandidateRequests()
    private weak var view: JournalNativeTextView?
    private var font = UIFont.systemFont(ofSize: 20)
    private var updating = false

    init(text: Binding<String>, composition: JournalNativeComposition? = JournalNativeComposition()) {
        self.text = text; self.composition = composition
    }

    func attach(_ view: JournalNativeTextView) {
        self.view = view
        view.delegate = self
        view.candidates.choose = { [weak self] index in self?.choose(index) }
        view.candidates.dismissKeyboard = { [weak self, weak view] in self?.commit(); view?.resignFirstResponder() }
        view.sectionAction = { [weak self] action, direction in self?.adjust(action, direction: direction) }
        view.pasteText = { [weak self] value in self?.paste(value) }
        requests.unavailable = { [weak self] in self?.reportFailure() }
        requests.receive = { [weak self] reading, result in
            guard let self else { return }
            _ = composition?.call("receive", [reading, result])
            decorate()
        }
    }

    func configure(text: String, font: UIFont) {
        self.font = font
        if composition?.state.text != text {
            requests.cancel()
            composition?.call("external", [text])
        }
        updating = true
        view?.configure(text: text, font: font)
        updating = false
        decorate()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
        guard !updating, textView.markedTextRange == nil, let composition else { return true }
        let roman = replacement.utf16.count == 1 && "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'-".contains(replacement)
        let punctuation = [".", ",", "?", "!", "/"].contains(replacement)
        // Let UIKit perform ordinary edits, especially Delete after a commit.
        guard composition.state.composition != nil || roman || punctuation else { return true }
        replace(replacement, range: range, literal: replacement.utf16.count > 1)
        schedule()
        return false
    }

    private func replace(_ replacement: String, range: NSRange, literal: Bool) {
        guard let view, let composition else { return }
        let selection = view.selectedRange
        let state = composition.call("edit", [["text": view.text ?? "", "range": [range.location, range.length],
            "replacement": replacement, "selection": [selection.location, selection.length], "literal": literal]])
        apply(state)
    }

    func paste(_ value: String) {
        guard let view else { return }
        guard composition != nil else { view.insertText(value); return }
        requests.cancel()
        replace(value, range: view.selectedRange, literal: true)
    }

    private func reportFailure() {
        guard !reportedFailure else { return }
        reportedFailure = true
        unavailable()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        focusChanged(textView.window.map { $0.convert($0.bounds, to: nil) })
        guard composition != nil else { reportFailure(); return }
        requests.prepare()
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !updating else { return }
        requests.cancel()
        composition?.call("external", [textView.text ?? ""])
        text.wrappedValue = textView.text
        view?.updatePlaceholder()
        view?.invalidateIntrinsicContentSize()
        view?.requestCaretReveal()
        decorate()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !updating, textView.text == composition?.state.text else { return }
        let selection = textView.selectedRange
        let previous = composition?.state.composition
        composition?.call("moveSelection", [[selection.location, selection.length]])
        if previous != nil && composition?.state.composition == nil { requests.cancel() }
        decorate()
        view?.requestCaretReveal()
    }

    func textViewDidEndEditing(_ textView: UITextView) { commit(); focusChanged(nil) }

    func choose(_ index: Int) {
        guard let state = composition?.call("choose", [index]) else { return }
        requests.cancel()
        apply(state)
    }

    func commit() {
        guard composition?.state.composition != nil, let state = composition?.call("commit") else { return }
        requests.cancel()
        apply(state)
    }

    func stop() { requests.cancel(); requests.receive = nil; requests.unavailable = nil }

    private func adjust(_ action: String, direction: Int) {
        guard let composition else { return }
        _ = composition.call(action, [direction])
        decorate()
        if action == "resize" { schedule(immediate: true) }
    }

    private func schedule(immediate: Bool = false) {
        guard let state = composition?.state else { return }
        requests.schedule(reading: state.reading, boundaries: state.boundaries, immediate: immediate)
    }

    private func apply(_ state: JournalInputSnapshot) {
        updating = true
        view?.configure(text: state.text, font: font)
        view?.selectedRange = NSRange(location: state.caret, length: 0)
        text.wrappedValue = state.text
        updating = false
        view?.updatePlaceholder()
        view?.invalidateIntrinsicContentSize()
        view?.requestCaretReveal()
        decorate()
    }

    private func decorate() {
        guard let view, view.markedTextRange == nil else { return }
        updating = true
        defer { updating = false }
        let all = NSRange(location: 0, length: view.textStorage.length)
        view.textStorage.removeAttribute(.underlineStyle, range: all)
        view.textStorage.removeAttribute(.backgroundColor, range: all)
        applyAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: composition?.state.composition)
        applyAttribute(.underlineColor, value: UIColor.systemBlue, range: composition?.state.composition)
        applyAttribute(.backgroundColor, value: UIColor.systemBlue.withAlphaComponent(0.12), range: composition?.state.section)
        view.candidates.update(composition?.state.choices ?? [], context: "\(composition?.state.reading ?? ""):\(composition?.state.section ?? [])")
        view.hasComposition = composition?.state.composition != nil
    }

    private func applyAttribute(_ key: NSAttributedString.Key, value: Any, range: [Int]?) {
        guard let view, let range, range.count == 2, range[0] >= 0, range[1] > 0,
              range[0] + range[1] <= view.textStorage.length else { return }
        view.textStorage.addAttribute(key, value: value, range: NSRange(location: range[0], length: range[1]))
    }

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard composition?.state.composition != nil else { return nil }
        let actions = [("Previous section", "focusSection", -1), ("Next section", "focusSection", 1),
                       ("Shorten section", "resize", -1), ("Lengthen section", "resize", 1)]
        let menu = actions.map { title, action, direction in
            UIAction(title: title) { [weak self] _ in self?.adjust(action, direction: direction) }
        }
        return UIMenu(children: suggestedActions + [UIMenu(title: "Conversion sections", children: menu)])
    }
}
