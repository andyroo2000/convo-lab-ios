import SwiftUI

struct JournalFinalEditor: View {
    let document: JournalDocumentModel
    let paperReply: Bool
    let close: () -> Void
    @State private var edit: JournalFinalEdit

    init(document: JournalDocumentModel, analysis: JournalAnalysis, paperReply: Bool, close: @escaping () -> Void) {
        self.document = document; self.paperReply = paperReply; self.close = close
        _edit = State(initialValue: JournalFinalEdit(analysis: analysis))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            JournalPaper(draft: document.entry.draft, reply: paperReply) {
                JournalWritingField(text: $edit.text, label: "Final text", minimumLines: 3)
                    .disabled(document.disabled)
            }
            if let message = document.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
                Text("Your edits are still here. If this entry changed elsewhere, copy your text before canceling and reopening it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Spacer(minLength: 0)
                Button("Cancel", action: close).buttonStyle(JournalDraftButtonStyle(sage: false))
                Button("Save changes") { Task { if await edit.save(document) { close() } } }
                    .buttonStyle(JournalDraftButtonStyle()).disabled(!edit.canSave)
            }.disabled(document.disabled)
            if edit.text.utf16.count > 30_000 { Text("Keep your final text under 30,000 characters.").foregroundStyle(.red) }
        }
    }
}

@MainActor
@Observable
final class JournalFinalEdit {
    nonisolated deinit {}
    var text: String
    private let original: String
    private let analysisID: String
    private let revision: Int?
    var canSave: Bool { revision != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= 30_000 }

    init(analysis: JournalAnalysis) {
        original = analysis.correctedText ?? ""
        text = original
        analysisID = analysis.id
        revision = analysis.replyRevision
    }

    func save(_ document: JournalDocumentModel) async -> Bool {
        guard canSave, let revision, !document.disabled else { return false }
        if text == original { return true }
        // Keep the opening revision even if a failed save refreshes the surrounding entry.
        return await document.save(.init(analysisId: analysisID, expectedRevision: revision, text: text))
    }
}
