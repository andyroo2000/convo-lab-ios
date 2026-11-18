import SwiftUI

/// UserDefaults is local to this installation; this preference never enters account sync.
enum JournalKeyboardMode: String, CaseIterable {
    static let key = "journal.keyboard.mode"
    case builtIn, device
    var shortName: String { self == .builtIn ? "Built-in" : "Device" }
}

struct JournalKeyboardMenuItem: View {
    @AppStorage(JournalKeyboardMode.key) private var mode = ""
    let open: () -> Void
    var body: some View {
        JournalOptionButton(title: "Keyboard", icon: "keyboard",
            detail: JournalKeyboardMode(rawValue: mode)?.shortName ?? "Choose", action: open)
            .accessibilityIdentifier("JournalKeyboardMenu")
    }
}

struct JournalWritingField: View {
    @Binding var text: String
    var label: String
    var minimumLines = 4
    var requestChoice = true
    @Environment(\.isEnabled) private var enabled
    @AppStorage(JournalKeyboardMode.key) private var mode = ""
    @State private var choosing = false

    var body: some View {
        Group {
            if mode == JournalKeyboardMode.builtIn.rawValue {
                JournalNeuralWritingField(text: $text, label: label, minimumLines: minimumLines)
            } else {
                JournalDeviceWritingField(text: $text, label: label, minimumLines: minimumLines)
                    .disabled(JournalKeyboardMode(rawValue: mode) == nil)
                    .overlay {
                        if JournalKeyboardMode(rawValue: mode) == nil {
                            Button("Choose keyboard") { choosing = true }
                                .buttonStyle(JournalDraftButtonStyle())
                        }
                    }
            }
        }
        .task(id: requestChoice && enabled) {
            if requestChoice && enabled { choosing = JournalKeyboardMode(rawValue: mode) == nil }
        }
        .sheet(isPresented: $choosing) { JournalKeyboardSheet(onboarding: true) }
    }
}
