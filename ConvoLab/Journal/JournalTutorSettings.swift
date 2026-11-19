import SwiftUI

extension EnvironmentValues {
    @Entry var journalTutorRevision = 0
}

struct JournalTutorSettings: View {
    let service: JournalService
    @Environment(\.dismiss) private var dismiss
    @State private var preferences: JournalTutorPreferences?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                HStack(spacing: 16) {
                    ForEach(preferences?.tutors ?? []) { tutor in
                        Button { Task { await choose(tutor) } } label: {
                            VStack(spacing: 8) {
                                JournalAvatar(url: tutor.avatarUrl).frame(width: 88, height: 88).clipShape(Circle())
                                if preferences?.selectedId == tutor.id { Image(systemName: "checkmark") }
                            }.frame(maxWidth: .infinity).padding(12)
                        }.buttonStyle(.plain).disabled(busy)
                            .accessibilityLabel(tutor.name)
                            .accessibilityAddTraits(preferences?.selectedId == tutor.id ? .isSelected : [])
                    }
                }
                if busy { ProgressView() }
                if let error {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { Task { await load() } }
                }
                Spacer()
            }.padding(20).navigationTitle("Choose your tutor")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.task { await load() }
    }

    private func load() async {
        busy = true; error = nil
        defer { busy = false }
        do { preferences = try await service.tutorPreferences() }
        catch { self.error = "Your tutors could not be loaded. Please try again." }
    }

    private func choose(_ tutor: JournalTutor) async {
        busy = true; error = nil
        defer { busy = false }
        do { preferences = try await service.chooseTutor(tutor.id); dismiss() }
        catch { self.error = "Your tutor could not be saved. Please choose again." }
    }
}
