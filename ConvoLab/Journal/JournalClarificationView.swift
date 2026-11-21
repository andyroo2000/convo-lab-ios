import SwiftUI

struct JournalClarificationView: View {
    let model: JournalClarificationModel
    let service: JournalService
    @State private var avatar: String?

    var body: some View {
        Group {
            if model.busy {
                JournalThinkingView(service: service, lastAnswer: model.lastAnswer)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    JournalAvatar(url: avatar).frame(width: 40, height: 40).accessibilityLabel("Your tutor")
                    VStack(alignment: .leading, spacing: 16) {
                        if let question = model.state?.question {
                            JournalClarificationChoices(question: question, model: model).id(question.id)
                        }
                        if let error = model.errorMessage {
                            Text(error).font(.footnote).foregroundStyle(.red)
                            if model.canRetry { Button("Retry") { model.retry() }.buttonStyle(JournalDraftButtonStyle()).disabled(model.busy) }
                        }
                        Button("Back to draft") { model.cancel() }.frame(minHeight: 44).underline().foregroundStyle(JournalDialogStyle.green)
                    }.frame(maxWidth: .infinity, alignment: .leading).modifier(JournalDialogCard())
                }
            }
        }.environment(\.colorScheme, .light)
            .task {
                guard let preferences = try? await service.tutorPreferences() else { return }
                let tutor = preferences.tutors.first { $0.id == preferences.selectedId } ?? preferences.tutors.first
                avatar = tutor?.avatarUrl
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Clarify your meaning")
    }
}

private struct JournalClarificationChoices: View {
    let question: JournalClarification.Question
    let model: JournalClarificationModel
    @State private var selection: Int?
    @State private var custom = ""
    @FocusState private var writing: Bool
    @AccessibilityFocusState private var questionFocused: Bool
    private var answer: String {
        guard let selection else { return "" }
        return selection == question.choices.count ? custom : question.choices[selection]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.prompt).font(JournalDialogStyle.body).padding(.bottom, 12).foregroundStyle(Color(uiColor: JournalPopoverStyle.ink))
                .accessibilityAddTraits(.isHeader).accessibilityFocused($questionFocused)
            ForEach(Array(question.choices.enumerated()), id: \.offset) { index, choice in
                option(choice, index: index)
            }
            option("Something else", index: question.choices.count)
            if selection == question.choices.count {
                TextField("Your answer", text: $custom, axis: .vertical).lineLimit(3...6)
                    .textFieldStyle(.plain).padding(12)
                    .background(.white, in: .rect(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(JournalDialogStyle.border) }
                    .padding(.top, 14).padding(.bottom, 6).focused($writing)
                    .onChange(of: custom) { custom = String(custom.prefix(2000)) }
            }
            Button("Answer") { writing = false; model.answer(answer) }
                .buttonStyle(JournalDraftButtonStyle())
                .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.disabled(model.busy || !model.canRetry)
            .onAppear { questionFocused = true }
    }

    private func option(_ title: String, index: Int) -> some View {
        Button {
            selection = index
            writing = index == question.choices.count
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: selection == index ? "largecircle.fill.circle" : "circle")
                Text(title).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(selection == index ? JournalDialogStyle.sage : .white, in: .rect(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(selection == index ? JournalDialogStyle.green : JournalDialogStyle.border) }
        }.buttonStyle(.plain).foregroundStyle(Color(uiColor: JournalPopoverStyle.ink))
            .accessibilityAddTraits(selection == index ? .isSelected : [])
    }
}
