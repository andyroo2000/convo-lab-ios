import SwiftUI

struct JournalTeacherView: View {
    let feedback: JournalFeedback?
    let knownKanji: Set<Character>
    @State private var showEnglish = false
    @State private var player = JournalAudioPlayer()
    @State private var model: JournalTutorModel

    init(entry: JournalEntryModel, analysis: JournalAnalysis, feedback: JournalFeedback, knownKanji: Set<Character>, savedQuestion: JournalTutorQuestion? = nil) {
        self.feedback = feedback
        self.knownKanji = knownKanji
        _model = State(initialValue: JournalTutorModel(entry: entry, analysis: analysis, savedQuestion: savedQuestion))
    }

    init(question: JournalTutorQuestion, parentID: String, service: JournalService, knownKanji: Set<Character>) {
        feedback = nil; self.knownKanji = knownKanji
        _model = State(initialValue: JournalTutorModel(entryID: parentID, service: service, savedQuestion: question))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.choosing { JournalTutorPicker(model: model) }
            questionRibbon
            if let error = player.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            if let error = model.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
                Button("Retry tutor") { Task { await model.load() } }.font(.footnote)
            }
        }.task { await model.load() }
            .onChange(of: model.question?.id) { player.stop() }
    }

    private var questionRibbon: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let tutor = model.question?.tutor {
                    JournalTutorPortrait(tutor: tutor).frame(width: 32, height: 32)
                        .clipShape(Circle()).accessibilityLabel("\(tutor.name), your tutor")
                }
                if let question = model.question, question.tutor != nil {
                    JournalQuestionAudioView(model: model, question: question, player: player).id(question.id)
                }
                Spacer(minLength: 0)
                JournalQuestionControls(busy: model.isBusy, showEnglish: $showEnglish) {
                    Task { await model.showPicker() }
                }
            }.padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(red: 0.894, green: 0.937, blue: 0.988))
                .overlay(alignment: .bottom) { JournalRibbonProgress(player: player) }
            JournalSentenceText(text: model.question?.reading ?? feedback?.questionReading ?? "", knownKanji: knownKanji, player: player)
                .environment(\.journalTypography, JournalTypography(font: "sans", size: 20))
                .padding(14)
            if showEnglish {
                Text(model.question?.translation ?? feedback?.questionTranslation ?? "")
                    .font(.custom("Georgia", size: 16, relativeTo: .body))
                    .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }.foregroundStyle(Color(uiColor: JournalPopoverStyle.ink))
            .background(.white).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.85, green: 0.90, blue: 0.95)))
            .environment(\.colorScheme, .light)
    }
}

private struct JournalTutorPicker: View {
    let model: JournalTutorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Choose your tutor").font(.headline)
                Spacer()
                if model.question?.tutor != nil { Button("Cancel") { model.choosing = false }.disabled(model.isBusy) }
            }
            HStack(spacing: 12) {
                ForEach(model.preferences?.tutors ?? []) { tutor in
                    Button { Task { await model.choose(tutor) } } label: {
                        VStack(spacing: 8) {
                            JournalTutorPortrait(tutor: tutor).frame(width: 80, height: 80).clipShape(Circle()).accessibilityHidden(true)
                            if model.preferences?.selectedId == tutor.id { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }.frame(maxWidth: .infinity).padding(12)
                            .background(Color.blue.opacity(0.06), in: .rect(cornerRadius: 12))
                    }.buttonStyle(.plain).disabled(model.isBusy)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(tutor.name)
                        .accessibilityAddTraits(model.preferences?.selectedId == tutor.id ? .isSelected : [])
                }
            }
            if model.isBusy { ProgressView("Saving tutor…") }
        }.padding(14).background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
    }
}

private struct JournalTutorPortrait: View {
    let tutor: JournalTutor
    var body: some View {
        JournalAvatar(url: tutor.avatarUrl)
    }
}
