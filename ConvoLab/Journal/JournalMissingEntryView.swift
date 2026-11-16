import SwiftUI

struct JournalMissingEntryView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("404 · Entry Not Found").font(.caption).foregroundStyle(.secondary)
            JournalAvatar(url: "/images/tutor-hana.webp").frame(width: 94, height: 94).accessibilityLabel("Your tutor")
            Text("Today’s phrase").font(.caption)
            StudyRubyText("見[み]つかりません。", knownKanji: [], pointSize: 28)
            Text("“I can’t find it.”").font(.custom("Georgia", size: 18))
            Text("Useful for missing keys, missing socks… and, apparently, missing pages. Let’s try your journal instead.")
                .font(.custom("Georgia", size: 16)).multilineTextAlignment(.center)
            Button("Back to Journal", action: returnToJournal).buttonStyle(JournalDraftButtonStyle())
        }.padding(24).frame(maxWidth: .infinity)
            .foregroundStyle(Color(uiColor: JournalPopoverStyle.ink))
            .background(Color(red: 1, green: 0.992, blue: 0.965), in: .rect(cornerRadius: 16))
            .environment(\.colorScheme, .light)
    }

    private func returnToJournal() { dismiss() }
}
