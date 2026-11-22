import SwiftUI

struct JournalDraftCloseSheet: View {
    let model: JournalEntryModel
    let closeEntry: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var avatar: String?
    @State private var busy = false
    @State private var error: String?
    @State private var visible = true

    var body: some View {
        JournalDialogSheet {
            HStack(spacing: 12) {
                JournalAvatar(url: avatar).frame(width: 56, height: 56).clipShape(Circle()).accessibilityLabel("Your tutor")
                JournalDialogHeading(title: "Keep this draft?", closeLabel: "Keep writing") { dismiss() }
            }
            Text("Your writing is saved automatically. You can come back and finish it later.")
                .font(.custom("CrimsonPro-Regular", size: 20, relativeTo: .body)).multilineTextAlignment(.leading)
            Button("Keep draft & close") { perform(delete: false) }.buttonStyle(JournalDraftButtonStyle())
            Button("Delete draft", role: .destructive) { perform(delete: true) }.buttonStyle(JournalDraftButtonStyle(sage: false, destructive: true))
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        }.disabled(busy).interactiveDismissDisabled(busy)
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .task {
                guard let preferences = try? await model.store.service.tutorPreferences() else { return }
                avatar = preferences.tutors.first(where: { $0.id == preferences.selectedId })?.avatarUrl
            }
    }

    private func perform(delete: Bool) {
        guard !busy else { return }
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                if delete { try await model.store.delete(id: model.id) }
                else {
                    guard await model.save(submit: false) || model.isSavedOnDevice else {
                        error = "Your writing remains on this device. " + (model.errorMessage ?? "The draft could not be saved online. Try again.")
                        return
                    }
                }
                guard visible else { return }
                dismiss()
                closeEntry()
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct JournalDraftButtonStyle: ButtonStyle {
    var sage = true
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    private var foreground: Color {
        if destructive { return sage ? JournalDialogStyle.paper : JournalDialogStyle.destructive }
        return sage ? JournalDialogStyle.paper : JournalDialogStyle.green
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(JournalDialogStyle.body)
            .foregroundStyle(foreground)
            .padding(.horizontal, 18).padding(.vertical, 10).frame(minHeight: 44)
            .background(sage ? (destructive ? JournalDialogStyle.destructive : JournalDialogStyle.green) : JournalDialogStyle.paper, in: Capsule())
            .overlay(Capsule().stroke(destructive ? JournalDialogStyle.destructive.opacity(0.4) : JournalDialogStyle.green.opacity(0.5)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
    }
}
