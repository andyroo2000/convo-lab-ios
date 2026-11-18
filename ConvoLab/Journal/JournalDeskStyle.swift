import SwiftUI

extension EnvironmentValues {
    @Entry var journalShowEntries: (() -> Void)?
}

struct JournalDeskStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(8)
            .background(Color(red: 1, green: 0.992, blue: 0.961), in: .rect(cornerRadius: 14))
            .overlay(alignment: .bottom) { UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4).fill(JournalDeskStyle.green).frame(height: 4) }
            .environment(\.colorScheme, .light)
    }
    static let green = Color(red: 0.224, green: 0.545, blue: 0.278)
}

struct JournalEntriesButton: View {
    @Environment(\.journalShowEntries) private var showEntries
    var body: some View {
        if let showEntries {
            Button(action: showEntries) { Label("My entries", systemImage: "book") }
                .font(.custom("CrimsonPro-Regular", size: 18, relativeTo: .body))
                .padding(.horizontal, 10).frame(minHeight: 44)
                .foregroundStyle(Color(red: 0.278, green: 0.4, blue: 0.298))
                .background(.white.opacity(0.5), in: Capsule())
                .overlay(Capsule().stroke(Color(red: 0.66, green: 0.74, blue: 0.64)))
                .buttonStyle(.plain)
        }
    }
}

struct JournalAppearanceMenu: View {
    @State private var showing = false
    @State private var showingKeyboard = false
    var body: some View {
        JournalOptionsMenu {
            JournalOptionButton(title: "Appearance", icon: "textformat") { showing = true }
            JournalKeyboardMenuItem { showingKeyboard = true }
        }
            .accessibilityLabel("More journal options")
            .outsideDismissibleSheet(isPresented: $showing) { JournalAppearance() }
            .sheet(isPresented: $showingKeyboard) { JournalKeyboardSheet() }
    }
}
