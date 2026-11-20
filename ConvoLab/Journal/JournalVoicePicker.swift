import SwiftUI

struct JournalVoicePicker: View {
    let voice: JournalVoiceSelection
    @Binding var choosing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Choose your narration voice").font(.headline)
                Spacer()
                Button("Cancel") { choosing = false }
            }
            Text("Used when you play the corrected version.").font(.footnote).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 12) {
                ForEach(voice.voices) { option in
                    Button { voice.selected = option.id; choosing = false } label: {
                        JournalAvatar(url: option.avatarUrl)
                            .frame(width: 80, height: 80)
                            .background(.white, in: Circle()).clipShape(Circle()).accessibilityHidden(true)
                            .frame(maxWidth: .infinity).padding(12)
                            .background(Color.blue.opacity(0.06), in: .rect(cornerRadius: 12))
                            .overlay(alignment: .bottomTrailing) {
                                if voice.selected == option.id {
                                    Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                                        .padding(8).accessibilityHidden(true)
                                }
                            }
                    }.buttonStyle(.plain).disabled(voice.isLoading || voice.errorMessage != nil)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(option.name)
                        .accessibilityAddTraits(voice.selected == option.id ? .isSelected : [])
                }
            }
        }.padding(14).background(.white, in: .rect(cornerRadius: 16))
    }
}
