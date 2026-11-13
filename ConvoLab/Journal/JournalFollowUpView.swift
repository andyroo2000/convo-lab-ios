import SwiftUI

struct JournalFollowUpView: View {
    let entry: JournalEntryModel
    let knownKanji: Set<Character>
    @State private var model: JournalReplyModel?
    @State private var loadingError: String?

    var body: some View {
        Group {
            if let model { JournalAnswerView(model: model, knownKanji: knownKanji) }
            else if let loadingError { Text(loadingError).foregroundStyle(.red) }
            else { ProgressView() }
        }.task {
            guard model == nil, let analysis = entry.analysis else { return }
            do {
                let storage = try JournalAnswerStorage(directory: entry.store.storage.directory, entryID: entry.id, analysisID: analysis.id)
                model = JournalReplyModel(entry: entry, storage: storage)
            } catch { loadingError = "The answer draft could not be opened." }
        }
    }
}

private struct JournalAnswerView: View {
    let model: JournalReplyModel
    let knownKanji: Set<Character>
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var answerFocused: Bool
    private var analysis: JournalAnalysis? { model.entry.analysis }
    private var disabled: Bool { model.isBusy || model.waiting }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            if !model.draft.replace, let analysis, let feedback = analysis.currentFeedback {
                JournalTeacherView(entry: model.entry, analysis: analysis, feedback: feedback, knownKanji: knownKanji)
                    .id(analysis.currentReply?.id ?? analysis.id)
            }
            if model.draft.replace { Text("Edit last answer").font(.headline) }
            TextEditor(text: Binding(get: { model.draft.answer }, set: { model.change($0) }))
                .modifier(JournalBodyFont()).frame(minHeight: 120).scrollContentBackground(.hidden)
                .padding(8).background(.white, in: .rect(cornerRadius: 12))
                .accessibilityLabel("Your answer (optional)").disabled(disabled).focused($answerFocused)
            if model.draft.answer.count > 5000 {
                Text("Keep the answer within 5,000 characters. Your full text is kept on this device.").font(.footnote).foregroundStyle(.red)
            }
            if let error = model.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            if model.processing { ProgressView("Adding your answer…") }
            HStack {
                if model.draft.replace { Button("Cancel") { model.cancelEdit() }.disabled(disabled) }
                Spacer()
                Button(model.draft.replace ? "Update answer" : "Add to entry") { Task { await model.submit() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.processing || model.draft.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.draft.answer.count > 5000)
            }
            if analysis?.currentReply != nil && !model.draft.replace {
                HStack {
                    Button("Edit last answer") { model.editLast() }
                    Spacer()
                    Button("Undo last addition") { Task { await model.undo() } }
                }.font(.footnote).disabled(disabled)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { answerFocused = false }
            }
        }
        .task(id: "\(model.pendingID ?? ""):\(model.isBusy):\(scenePhase)") {
            if scenePhase == .active && !model.isBusy { await model.monitor() }
        }
        .onChange(of: analysis?.replyRevision) { model.reconcile() }
    }
}
