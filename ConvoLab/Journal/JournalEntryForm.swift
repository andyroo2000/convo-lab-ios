import SwiftUI

struct JournalEntryForm: View {
    let model: JournalEntryModel
    var onClose: (() -> Void)? = nil
    var showActions = true

    private var exceedsLimit: Bool {
        (model.draft?.body.unicodeScalars.count ?? 0) > 20_000 || (model.draft?.title?.unicodeScalars.count ?? 0) > 255
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            JournalPaper(draft: model.draft, writing: true) {
                JournalWritingField(text: writingBinding(), label: "Journal entry", requestChoice: model.draft != nil)
            }
            if exceedsLimit {
                Text("Keep the entry within 20,000 characters. Your full text is saved on this device.")
                    .font(.footnote).foregroundStyle(.red)
            }
            if showActions { JournalDraftActions(model: model, onClose: onClose) }
        }
        .disabled(model.isBusy || model.store.busyEntryIDs.contains(model.id) || model.analysis?.status.isPending == true)
    }

    private func writingBinding() -> Binding<String> {
        Binding(get: { model.draft?.body ?? "" }, set: { value in model.change { $0.body = value } })
    }

}
