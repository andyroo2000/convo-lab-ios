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
        VStack(spacing: 20) {
            JournalAvatar(url: avatar).frame(width: 72, height: 72).clipShape(Circle()).accessibilityLabel("Your tutor")
            Text("Keep this draft?").font(.custom("CrimsonPro-Regular", size: 28, relativeTo: .title2))
            Text("Your writing is saved automatically. You can come back and finish it later.")
                .font(.custom("CrimsonPro-Regular", size: 20, relativeTo: .body)).multilineTextAlignment(.center)
            Button("Keep draft & close") { perform(delete: false) }.buttonStyle(JournalDraftButtonStyle())
            Button("Delete draft", role: .destructive) { perform(delete: true) }.buttonStyle(JournalDraftButtonStyle(sage: false))
            Button("Keep writing") { dismiss() }.frame(minHeight: 44)
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        }.padding(24).disabled(busy).interactiveDismissDisabled(busy)
            .presentationDetents([.medium, .large]).presentationBackground(Color(red: 1, green: 0.992, blue: 0.965)).environment(\.colorScheme, .light)
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
                    guard await model.save(submit: false) else {
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
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.custom("CrimsonPro-Regular", size: 20, relativeTo: .body))
            .foregroundStyle(sage ? Color(red: 0.278, green: 0.4, blue: 0.298) : Color(red: 0.459, green: 0.38, blue: 0.314))
            .padding(.horizontal, 18).padding(.vertical, 10).frame(minHeight: 44)
            .background(sage ? Color(red: 0.929, green: 0.953, blue: 0.914) : Color(red: 0.984, green: 0.961, blue: 0.945), in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(sage ? Color(red: 0.604, green: 0.702, blue: 0.616) : Color(red: 0.804, green: 0.741, blue: 0.682)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
    }
}
