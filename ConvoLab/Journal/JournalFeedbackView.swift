import SwiftUI

struct JournalFeedbackView: View {
    let model: JournalEntryModel
    let knownKanji: Set<Character>
    let followUp: Bool
    let nested: Bool
    @State private var voice = JournalVoiceSelection()
    @State private var choosingVoice = false
    @State private var version = JournalVersion.final
    @State private var document: JournalDocumentModel

    init(model: JournalEntryModel, knownKanji: Set<Character>, followUp: Bool = true, nested: Bool = false) {
        self.followUp = followUp
        self.nested = nested
        self.model = model
        self.knownKanji = knownKanji
        _document = State(initialValue: JournalDocumentModel(entry: model))
    }
    var body: some View {
        if let analysis = model.analysis, let result = analysis.result {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(nested ? "Your reply" : model.draft?.title ?? "Untitled entry").font(.largeTitle.bold()).foregroundStyle(Color(uiColor: JournalPopoverStyle.ink))
                    Text(JournalDates.heading(model.draft?.entryDate ?? ""))
                        .font(.system(size: 15).monospacedDigit())
                        .foregroundStyle(Color(red: 163 / 255, green: 170 / 255, blue: 182 / 255))
                        .accessibilityIdentifier("JournalEntryDate")
                }
                HStack(spacing: 8) {
                    JournalVersionPicker(selection: $version)
                    JournalVersionCopy(version: version, analysis: analysis)
                    if version == .final { JournalVoiceButton(voice: voice, choosing: $choosingVoice) }
                }
                if version == .draft {
                    JournalHighlights(segments: result.segments, knownKanji: knownKanji, document: document, sourceID: analysis.id)
                    if let reply = analysis.currentReply, let feedback = reply.result {
                        Text("Your last answer").font(.subheadline).foregroundStyle(.secondary)
                        JournalHighlights(segments: feedback.segments, knownKanji: knownKanji, document: document, sourceID: reply.id)
                    }
                } else {
                    JournalCorrectedView(document: document, analysis: analysis, knownKanji: knownKanji, voice: voice, choosingVoice: $choosingVoice, compact: true)
                }
                if followUp { JournalFollowUpView(entry: model, knownKanji: knownKanji).id(analysis.id) }
            }.onChange(of: analysis.id) { version = .final }
                .onChange(of: version) { choosingVoice = false }
        }
    }
}
