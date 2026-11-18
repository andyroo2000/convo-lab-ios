import SwiftUI

private struct JournalWritingFocusKey: EnvironmentKey {
    static let defaultValue: (CGRect?) -> Void = { _ in }
}

extension EnvironmentValues {
    var journalWritingFocus: (CGRect?) -> Void {
        get { self[JournalWritingFocusKey.self] }
        set { self[JournalWritingFocusKey.self] = newValue }
    }
}

struct JournalKeyboardDock {
    var focusedWindow: CGRect?
    var keyboardFrame = CGRect.zero

    var visible: Bool {
        guard let window = focusedWindow else { return false }
        let overlap = window.intersection(keyboardFrame)
        return overlap.height > 0 && overlap.width >= window.width - 1 && keyboardFrame.maxY >= window.maxY - 1
    }
}
