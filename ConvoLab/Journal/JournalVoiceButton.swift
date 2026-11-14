import SwiftUI

struct JournalVoiceButton: View {
    let voice: JournalVoiceSelection
    @Binding var choosing: Bool

    var body: some View {
        Button { choosing.toggle() } label: {
            Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44)
        }
        .disabled(!voice.isReady)
        .accessibilityLabel("Narration voice")
        .accessibilityIdentifier("JournalVoicePicker")
        .accessibilityHint(choosing ? "Voice choices expanded" : "Opens voice choices")
        .accessibilityValue(voice.voices.first(where: { $0.id == voice.selected })?.name ?? "Not selected")
    }
}
