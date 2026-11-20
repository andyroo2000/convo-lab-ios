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

    @State private var showingMenu = false
    @State private var pendingAction: (() -> Void)?

    var body: some View {
        Button {
            showingMenu = true
        } label: {
            Text(name.first.map { String($0).uppercased() } ?? "?")
                .font(.custom("Anton-Regular", fixedSize: 25))
                .foregroundStyle(ConvoLabTheme.navy)
                .frame(width: 36, height: 36)
                .background(ConvoLabTheme.cream, in: Circle())
                .padding(4).background(JournalBrandStyle.spine.opacity(0.5), in: Circle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingMenu, arrowEdge: .top) {
            accountOptions.onDisappear {
                let perform = pendingAction
                pendingAction = nil
                perform?()
            }
        }
        .confirmationDialog("Log out of ConvoLab?", isPresented: $confirmingLogout, titleVisibility: .visible) {
            Button("Log out", role: .destructive) { logout?() }
        } message: {
            Text("Changes saved on this device will sync when you sign back in to this account.")
        }
        .accessibilityLabel("Account menu")
        .accessibilityIdentifier("app-account-menu")
    }
    private var accountOptions: some View {
        AppPaperMenu {
            if selection == .journal, !journalActions.isEmpty {
                AppPaperMenuGroup(title: "Journal") {
                    ForEach(journalActions) { item in
                        AppPaperMenuRow(title: item.title, icon: item.icon ?? "ellipsis") { choose(item.perform) }
                            .disabled(!item.isEnabled)
                            .accessibilityIdentifier(item.id)
                    }
                }
                Divider().padding(.horizontal, 12)
            }
            AppPaperMenuGroup(title: "Account") {
                AppPaperMenuRow(title: "Settings", icon: "gearshape") { choose { selection = .settings } }
                if logout != nil {
                    AppPaperMenuRow(title: "Log out", icon: "rectangle.portrait.and.arrow.right") {
                        choose { confirmingLogout = true }
                    }
                }
            }.disabled(preventsNavigation)
        }
    }

    private func choose(_ perform: @escaping () -> Void) {
        pendingAction = perform
        showingMenu = false
    }
}
