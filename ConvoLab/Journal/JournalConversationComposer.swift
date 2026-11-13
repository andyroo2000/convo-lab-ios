import SwiftUI

struct JournalConversationComposer: View {
    let entry: JournalEntryModel
    let analysis: JournalAnalysis
    let knownKanji: Set<Character>
    let refresh: () async -> Bool
    @State private var answer: JournalConversationAnswer
    @FocusState private var writing: Bool

    init(entry: JournalEntryModel, rootID: String, analysis: JournalAnalysis, knownKanji: Set<Character>, refresh: @escaping () async -> Bool) {
        self.entry = entry; self.analysis = analysis; self.knownKanji = knownKanji; self.refresh = refresh
        _answer = State(initialValue: JournalConversationAnswer(entry: entry, rootID: rootID, analysisID: analysis.id))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let feedback = analysis.currentFeedback {
                JournalTeacherView(entry: entry, analysis: analysis, feedback: feedback, knownKanji: knownKanji)
            }
            TextEditor(text: $answer.body).modifier(JournalBodyFont()).frame(minHeight: 120)
                .foregroundStyle(Color(uiColor: JournalPopoverStyle.ink)).environment(\.colorScheme, .light)
                .padding(10).background(.white, in: .rect(cornerRadius: 12))
                .focused($writing).accessibilityLabel("Your answer").disabled(answer.busy || answer.request != nil)
                .onChange(of: answer.body) { answer.save() }
            if let error = answer.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
                Button("Reload conversation") { Task { await refresh() } }
            }
            Button(answer.busy ? "Submitting…" : "Submit") {
                Task { await submit() }
            }.buttonStyle(.borderedProminent).disabled(answer.busy || answer.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.toolbar {
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { writing = false } }
        }
    }
    private func submit() async {
        do {
            if let request = answer.request {
                await answer.submit(questionID: request.questionId, refresh: refresh)
                return
            }
            let current = try await entry.store.service.prepareQuestion(entryID: entry.id, input: JournalQuestionInput(analysisId: analysis.id, replyId: analysis.currentReply?.id))
            guard current.tutor != nil else { answer.errorMessage = "Choose your tutor before sending an answer."; return }
            await answer.submit(questionID: current.id, refresh: refresh)
        } catch { answer.errorMessage = error.localizedDescription }
    }
}
