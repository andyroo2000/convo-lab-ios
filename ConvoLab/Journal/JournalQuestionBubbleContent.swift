import SwiftUI

struct JournalQuestionBubbleContent: View {
    let reading: String
    let translation: String
    let knownKanji: Set<Character>
    let busy: Bool
    let player: JournalAudioPlayer
    let choose: () -> Void
    @State private var showEnglish = false

    var body: some View {
        JournalSentenceText(text: reading, knownKanji: knownKanji, player: player, reserveControls: true)
            .frame(minHeight: 44)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 0) {
                    Button { showEnglish.toggle() } label: {
                        Text("En").font(.caption.weight(.semibold)).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(showEnglish ? "Hide English" : "Show English")
                        .accessibilityInputLabels(["En", "English"])
                        .popover(isPresented: $showEnglish) {
                            Text(translation).font(.subheadline).foregroundStyle(Color(uiColor: JournalPopoverStyle.ink))
                                .padding(16).frame(idealWidth: 280, maxWidth: 300)
                                .presentationCompactAdaptation(.popover)
                                .environment(\.colorScheme, .light)
                        }
                    Button(action: choose) {
                        Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("Choose tutor").disabled(busy)
                }
            }
    }
}
