import SwiftUI

extension EnvironmentValues {
    @Entry var appAccountName = ""
    @Entry var appAccountLogout: (() -> Void)?
}

struct AppAccountMenu: View {
    @Environment(\.appAccountName) private var name
    @Environment(\.appAccountLogout) private var logout
    @Binding var selection: AppMode
    let journalActions: [AppModeToolbarAction]
    var preventsNavigation = false
    @State private var confirmingLogout = false

    var body: some View {
        Menu {
            if selection == .journal, !journalActions.isEmpty {
                Section("Journal") {
                    ForEach(journalActions) { item in
                        Button(item.title, action: item.perform)
                            .disabled(!item.isEnabled)
                            .accessibilityIdentifier(item.id)
                    }
                }
            }
            Section("Account") {
                Button("Settings", systemImage: "gearshape") { selection = .settings }
                    .disabled(preventsNavigation)
                if logout != nil {
                    Button("Log out", systemImage: "rectangle.portrait.and.arrow.right") { confirmingLogout = true }
                        .disabled(preventsNavigation)
                }
            }
        } label: {
            Text(name.first.map { String($0).uppercased() } ?? "?")
                .font(.custom("Anton-Regular", fixedSize: 25))
                .foregroundStyle(ConvoLabTheme.navy)
                .frame(width: 36, height: 36)
                .background(ConvoLabTheme.cream, in: Circle())
                .padding(4).background(JournalBrandStyle.spine.opacity(0.5), in: Circle())
        }
        .confirmationDialog("Log out of ConvoLab?", isPresented: $confirmingLogout, titleVisibility: .visible) {
            Button("Log out", role: .destructive) { logout?() }
        } message: {
            Text("Changes saved on this device will sync when you sign back in to this account.")
        }
        .accessibilityLabel("Account menu")
        .accessibilityIdentifier("app-account-menu")
    }
}
