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
            Text("Leave this draft?").font(.title2)
            Button("Keep draft & close") { perform(delete: false) }.buttonStyle(JournalDraftButtonStyle())
            Button("Delete draft", role: .destructive) { perform(delete: true) }.frame(minHeight: 44)
            Button("Keep writing") { dismiss() }.frame(minHeight: 44)
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        }.padding(24).disabled(busy).interactiveDismissDisabled(busy)
            .presentationDetents([.medium, .large])
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
                        error = model.errorMessage ?? "The draft could not be saved. Keep writing and try again."
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.custom("KleeOne-SemiBold", size: 18, relativeTo: .body))
            .foregroundStyle(Color(red: 0.24, green: 0.34, blue: 0.27))
            .padding(.horizontal, 18).padding(.vertical, 10).frame(minHeight: 44)
            .background(Color(red: 0.88, green: 0.92, blue: 0.86), in: .rect(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}
