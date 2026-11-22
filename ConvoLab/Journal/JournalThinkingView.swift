import SwiftUI

struct JournalThinkingView: View {
    let service: JournalService
    var lastAnswer: String?
    @State private var phrase = JournalThinkingPhrases.next()
    @State private var avatar: String?
    @State private var english = true
    @State private var openedAt = Date()
    @ScaledMetric(relativeTo: .body) private var phraseSize = 21.0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Button(english ? "Hide English" : "Show English") { english.toggle() }
                .font(.caption).frame(maxWidth: .infinity, alignment: .trailing)
            JournalThinkingOrnament()
            JournalAvatar(url: avatar).frame(width: 80, height: 80).clipShape(Circle()).accessibilityLabel("Your tutor").padding(.top, 10)
            Text(phrase.japanese).font(.system(size: phraseSize)).multilineTextAlignment(.center)
            if english { Text(phrase.english).font(.custom("CrimsonPro-Regular", size: 19, relativeTo: .body)) }
            JournalThinkingDots().padding(.top, 6)
            if let lastAnswer {
                Divider().overlay(Color(red: 0.867, green: 0.847, blue: 0.788)).padding(.top, 18)
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark").accessibilityHidden(true).font(.system(size: 16)).foregroundStyle(Color(red: 0.416, green: 0.510, blue: 0.404))
                    Text(lastAnswer).font(.custom("CrimsonPro-Regular", size: 17, relativeTo: .body))
                        .foregroundStyle(Color(red: 0.349, green: 0.298, blue: 0.267))
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }.accessibilityIdentifier("JournalLastClarificationAnswer")
            }
            TimelineView(.periodic(from: openedAt, by: 1)) { context in
                if context.date.timeIntervalSince(openedAt) >= 60 {
                    Text("This is taking longer than usual. Your writing is saved.").font(.footnote)
                    Button("Return to journal") { dismiss() }.frame(minHeight: 44)
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 32).frame(maxWidth: .infinity)
            .background(Color(red: 1, green: 0.992, blue: 0.965), in: .rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(Color(red: 0.847, green: 0.894, blue: 0.949)) }
            .foregroundStyle(Color(uiColor: JournalPopoverStyle.ink))
            .environment(\.colorScheme, .light)
            .accessibilityIdentifier("JournalFeedbackProgress")
            .task { await loadTutor() }
    }

    private func loadTutor() async {
        guard let preferences = try? await service.tutorPreferences() else { return }
        avatar = (preferences.tutors.first(where: { $0.id == preferences.selectedId }) ?? preferences.tutors.first)?.avatarUrl
    }
}
