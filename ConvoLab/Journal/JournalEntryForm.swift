import SwiftUI

struct JournalEntryForm: View {
    let model: JournalEntryModel
    @Environment(\.dismiss) private var dismiss
    @State private var closing = false

    private var exceedsLimit: Bool {
        (model.draft?.body.unicodeScalars.count ?? 0) > 20_000 || (model.draft?.title?.unicodeScalars.count ?? 0) > 255
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            JournalPaper(draft: model.draft, writing: true) {
                JournalWritingField(text: writingBinding(), label: "Journal entry")
            }
            if exceedsLimit {
                Text("Keep the entry within 20,000 characters and its title within 255. Your full text is saved on this device.")
                    .font(.footnote).foregroundStyle(.red)
            }
            HStack {
                Button("Close") { closing = true }.buttonStyle(JournalDraftButtonStyle())
                Spacer()
                Button("Submit") { Task { await model.save(submit: true) } }
                    .buttonStyle(JournalDraftButtonStyle())
                    .disabled(model.draft?.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
            }.disabled(exceedsLimit)
        }
        .sheet(isPresented: $closing) { JournalDraftCloseSheet(model: model) { dismiss() } }
        .disabled(model.isBusy || model.store.busyEntryIDs.contains(model.id) || model.analysis?.status.isPending == true)
    }

    private func writingBinding() -> Binding<String> {
        Binding(get: { model.draft?.body ?? "" }, set: { value in model.change { $0.body = value } })
    }

}
