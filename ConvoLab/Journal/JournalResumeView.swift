import SwiftUI

struct JournalResumeView: View {
    let store: JournalStore
    let select: (String) -> Void
    @State private var remoteID: String?

    private var localID: String? {
        store.drafts.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.entryDate, $0.id) > ($1.entryDate, $1.id) }.first?.id
    }

    var body: some View {
        Group {
            if let id = localID ?? remoteID {
                Button("Continue draft") { select(id) }.buttonStyle(JournalDraftButtonStyle(sage: false))
            }
        }
        .task {
            guard localID == nil else { return }
            remoteID = try? await JournalUnfinishedEntry.find(entries: store.entries, cursor: store.nextCursor, service: store.service)
        }
    }
}
