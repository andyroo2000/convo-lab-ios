import SwiftUI

struct JournalTeacherView: View {
    let feedback: JournalFeedback?
    let knownKanji: Set<Character>
    @State private var model: JournalTutorModel
    @State private var showEnglish = false
    @Environment(\.scenePhase) private var scenePhase

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
            HStack(alignment: .top, spacing: 12) {
                if let tutor = model.question?.tutor {
                    JournalTutorPortrait(tutor: tutor).frame(width: 56, height: 56)
                        .clipShape(Circle()).accessibilityLabel("\(tutor.name), your tutor")
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()
                        Button { Task { await model.showPicker() } } label: {
                            Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44)
                        }.accessibilityLabel("Choose tutor").disabled(model.isBusy)
                    }
                    JournalRubyText(text: model.question?.reading ?? feedback?.questionReading ?? "", knownKanji: knownKanji)
                    if let question = model.question, question.tutor != nil { JournalQuestionAudioView(model: model, question: question).id(question.id) }
                    Button("EN") { showEnglish.toggle() }.font(.caption.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel(showEnglish ? "Hide English" : "Show English")
                        .accessibilityInputLabels(["EN", "English"])
                        .accessibilityValue(showEnglish ? "Expanded" : "Collapsed")
                    if showEnglish { Text(model.question?.translation ?? feedback?.questionTranslation ?? "").font(.subheadline).foregroundStyle(.secondary) }
                }.foregroundStyle(Color(uiColor: JournalPopoverStyle.ink))
                    .environment(\.colorScheme, .light)
                    .padding(14).background(JournalSpeechBubble().fill(Color(red: 237 / 255, green: 245 / 255, blue: 1)))
            }
            if let error = model.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
                Button("Retry tutor") { Task { await model.load() } }.font(.footnote)
            }
        }.task { await model.load() }
            .task(id: "\(model.question?.id ?? ""):\(model.question?.audio?.status ?? ""):\(scenePhase)") {
                if scenePhase == .active { await model.monitorAudio() }
            }
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
            Text("Used for new questions on all your devices. Earlier questions keep their tutor.").font(.footnote).foregroundStyle(.secondary)
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
