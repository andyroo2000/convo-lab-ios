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
                        VStack(spacing: 8) {
                            JournalAvatar(url: option.avatarUrl).frame(width: 80, height: 80)
                                .clipShape(Circle()).accessibilityHidden(true)
                            Text(option.name).font(.subheadline.bold())
                            if voice.selected == option.id { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }.frame(maxWidth: .infinity).padding(12)
                            .background(Color.blue.opacity(0.06), in: .rect(cornerRadius: 12))
                    }.buttonStyle(.plain).disabled(voice.isLoading || voice.errorMessage != nil)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(voice.selected == option.id ? .isSelected : [])
                }
            }
        }.padding(14).background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
    }
}
