import SwiftUI

struct JournalResumeView: View {
    let store: JournalStore
    let select: (String) -> Void
    @State private var remoteID: String?
    @State private var failed = false
    @State private var attempt = 0

    private var localID: String? {
        store.drafts.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.entryDate, $0.id) > ($1.entryDate, $1.id) }.first?.id
    }

    private var lookupKey: String {
        let archive = store.entries.map { "\($0.id):\($0.version)" }.joined(separator: ",")
        return "\(localID ?? ""):\(attempt):\(archive)"
    }

    var body: some View {
        Group {
            if let id = localID ?? remoteID {
                Button("Continue draft") { select(id) }.buttonStyle(JournalDraftButtonStyle(sage: false))
            } else if failed {
                HStack {
                    Text("Couldn’t check saved drafts.").font(.footnote)
                    Button("Retry") { attempt += 1 }
                }
            }
        }
        .task(id: lookupKey) { await findDraft() }
    }

    private func findDraft() async {
        remoteID = nil
        failed = false
        guard localID == nil else { return }
        do { remoteID = try await JournalUnfinishedEntry.find(service: store.service) }
        catch is CancellationError { }
        catch { failed = true }
    }
}
