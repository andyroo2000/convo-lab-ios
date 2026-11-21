import SwiftUI

struct JournalVoicePicker: View {
    let voice: JournalVoiceSelection
    @Binding var choosing: Bool

    var body: some View {
        JournalDialogSheet {
            JournalDialogHeading(title: "Narration voice", closeLabel: "Cancel") { choosing = false }
            Text("Used when you play the corrected version.").foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(voice.voices) { option in
                    Button { voice.selected = option.id; choosing = false } label: {
                        JournalAvatarChoice(url: option.avatarUrl, selected: voice.selected == option.id)
                    }.buttonStyle(.plain).disabled(voice.isLoading || voice.errorMessage != nil)
                        .accessibilityLabel(option.name)
                        .accessibilityAddTraits(voice.selected == option.id ? .isSelected : [])
                }
            }
        }
    }
}
