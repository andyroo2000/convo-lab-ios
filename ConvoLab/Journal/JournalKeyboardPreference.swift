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
    var autofocus = false
    @Environment(\.isEnabled) private var enabled
    @AppStorage(JournalKeyboardMode.key) private var mode = ""
    @State private var choosing = false
    @State private var inputUnavailable = false

    var body: some View {
        Group {
            if mode == JournalKeyboardMode.builtIn.rawValue {
                JournalNeuralWritingField(text: $text, label: label, minimumLines: minimumLines, autofocus: autofocus, unavailable: { inputUnavailable = true })
            } else {
                JournalDeviceWritingField(text: $text, label: label, minimumLines: minimumLines, autofocus: autofocus)
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
        .alert("Japanese input couldn’t start", isPresented: $inputUnavailable) {
            Button("Use device keyboard") { mode = JournalKeyboardMode.device.rawValue }
        } message: {
            Text("Your writing is safe. Switch to your device’s keyboard to keep writing. You can try built-in input again from Keyboard settings.")
        }
        .sheet(isPresented: $choosing) { JournalKeyboardSheet(onboarding: true) }
    }
}
