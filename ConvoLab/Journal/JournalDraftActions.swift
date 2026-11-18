import SwiftUI

struct JournalDraftActions: View {
    let model: JournalEntryModel
    var onClose: (() -> Void)? = nil
    var requestClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var closing = false

    private var exceedsLimit: Bool {
        (model.draft?.body.unicodeScalars.count ?? 0) > 20_000 || (model.draft?.title?.unicodeScalars.count ?? 0) > 255
    }

    var body: some View {
        HStack {
            Button("Close") {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                if let requestClose { requestClose() }
                else if model.isUnwritten { close() }
                else { closing = true }
            }.buttonStyle(JournalDraftButtonStyle(sage: false))
            Spacer()
            Button("Submit") {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                Task { await model.save(submit: true) }
            }
                .buttonStyle(JournalDraftButtonStyle())
                .disabled(model.draft?.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false || exceedsLimit)
        }
        .sheet(isPresented: $closing) { JournalDraftCloseSheet(model: model, closeEntry: close) }
        .disabled(model.isBusy || model.store.busyEntryIDs.contains(model.id) || model.analysis?.status.isPending == true)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
}
