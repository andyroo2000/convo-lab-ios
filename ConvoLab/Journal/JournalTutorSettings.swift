import SwiftUI

extension EnvironmentValues {
    @Entry var journalTutorRevision = 0
}

struct JournalTutorSettings: View {
    let service: JournalService
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preferences: JournalTutorPreferences?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        JournalDialogSheet {
            JournalDialogHeading(title: "Choose your tutor", closeLabel: "Close tutor picker") { dismiss() }
            HStack(spacing: 12) {
                ForEach(preferences?.tutors ?? []) { tutor in
                    Button { Task { await choose(tutor) } } label: {
                        JournalAvatarChoice(url: tutor.avatarUrl, selected: preferences?.selectedId == tutor.id)
                    }.buttonStyle(.plain).disabled(busy)
                        .accessibilityLabel(tutor.name)
                        .accessibilityAddTraits(preferences?.selectedId == tutor.id ? .isSelected : [])
                }
            }
            if busy { ProgressView() }
            if let error {
                Text(error).foregroundStyle(JournalDialogStyle.destructive)
                Button("Retry") { Task { await load() } }.buttonStyle(JournalDraftButtonStyle())
            }
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
        do { preferences = try await service.chooseTutor(tutor.id); changed(); dismiss() }
        catch { self.error = "Your tutor could not be saved. Please choose again." }
    }
}
