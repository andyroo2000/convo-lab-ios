import SwiftUI

struct JournalCorrectedView: View {
    let document: JournalDocumentModel
    let analysis: JournalAnalysis
    let knownKanji: Set<Character>
    @State private var edit: CorrectedEdit?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Corrected Version").font(.headline)
                Spacer()
                Button {
                    document.errorMessage = nil
                    edit = CorrectedEdit(analysis: analysis)
                } label: {
                    Image(systemName: "pencil").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }.accessibilityLabel("Edit corrected version").disabled(document.disabled)
                Button { UIPasteboard.general.string = analysis.correctedText } label: {
                    Image(systemName: "doc.on.doc").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }.accessibilityLabel("Copy corrected version")
            }
            JournalAudioControls(entryID: document.entry.id, analysis: analysis, service: document.entry.store.service)
                .id("\(analysis.id):\(analysis.replyRevision ?? 0)")
            StudyRubyText(analysis.correctedReading ?? "", knownKanji: knownKanji, pointSize: 20, alignment: .left, extraLineSpacing: 10)
            if let error = document.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
        }.sheet(item: $edit) { draft in JournalCorrectedEditor(document: document, draft: draft) }
    }
}

private struct CorrectedEdit: Identifiable {
    let id = UUID()
    let analysisID: String
    let revision: Int
    let text: String
    init(analysis: JournalAnalysis) {
        analysisID = analysis.id
        revision = analysis.replyRevision ?? 0
        text = analysis.correctedText ?? ""
    }
}

private struct JournalCorrectedEditor: View {
    let document: JournalDocumentModel
    let draft: CorrectedEdit
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(document: JournalDocumentModel, draft: CorrectedEdit) {
        self.document = document
        self.draft = draft
        _text = State(initialValue: draft.text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $text).font(.title3).lineSpacing(8)
                    .accessibilityLabel("Corrected entry text").disabled(document.isBusy)
                if let error = document.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                    Button("Copy my edits") { UIPasteboard.general.string = text }
                }
                if document.isBusy { ProgressView("Saving and adding furigana…") }
            }.padding().navigationTitle("Edit corrected entry").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.disabled(document.isBusy)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await save() } }
                            .disabled(document.disabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 30000)
                    }
                }
        }.interactiveDismissDisabled(document.isBusy || text != draft.text)
    }

    private func save() async {
        let payload = JournalCorrectedPayload(analysisId: draft.analysisID, expectedRevision: draft.revision, text: text)
        if await document.save(payload) { dismiss() }
    }
}
