import SwiftUI

struct JournalThinkingView: View {
    let service: JournalService
    @State private var avatar: String?
    @State private var english = true
    @State private var openedAt = Date()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Button(english ? "Hide English" : "Show English") { english.toggle() }
                .font(.caption).frame(maxWidth: .infinity, alignment: .trailing)
            JournalAvatar(url: avatar).frame(width: 80, height: 80).clipShape(Circle()).accessibilityLabel("Your tutor")
            Text("少し待ってくださいね。").font(.title3)
            if english { Text("I'm preparing your feedback. Your writing is saved.").font(.custom("Georgia", size: 16, relativeTo: .body)) }
            ProgressView().accessibilityLabel("Your tutor is thinking")
            TimelineView(.periodic(from: openedAt, by: 1)) { context in
                if context.date.timeIntervalSince(openedAt) >= 60 {
                    Text("This is taking longer than usual. Your writing is saved.").font(.footnote)
                    Button("Return to journal") { dismiss() }.frame(minHeight: 44)
                }
            }
        }.padding(24).frame(maxWidth: .infinity)
            .background(Color(red: 1, green: 0.992, blue: 0.965), in: .rect(cornerRadius: 16))
            .foregroundStyle(Color(uiColor: JournalPopoverStyle.ink))
            .environment(\.colorScheme, .light)
            .accessibilityIdentifier("JournalFeedbackProgress")
            .task { await loadTutor() }
    }

    private func loadTutor() async {
        guard let preferences = try? await service.tutorPreferences() else { return }
        avatar = preferences.tutors.first(where: { $0.id == preferences.selectedId })?.avatarUrl
    }
}
