import SwiftUI

struct JournalFeedbackView: View {
    let model: JournalEntryModel
    let knownKanji: Set<Character>
    let followUp: Bool
    let nested: Bool
    @Environment(\.journalShowEntries) private var showEntries
    @State private var voice = JournalVoiceSelection()
    @State private var choosingVoice = false
    @AppStorage private var version: JournalVersion
    @State private var document: JournalDocumentModel

    init(model: JournalEntryModel, knownKanji: Set<Character>, followUp: Bool = true, nested: Bool = false) {
        _version = AppStorage(wrappedValue: .draft, JournalVersion.preferenceKey(owner: model.store.storage.directory.lastPathComponent, entry: model.id))
        self.followUp = followUp
        self.nested = nested
        self.model = model
        self.knownKanji = knownKanji
        _document = State(initialValue: JournalDocumentModel(entry: model))
    }
    var body: some View {
        if let analysis = model.analysis, let result = analysis.result {
            VStack(alignment: .leading, spacing: 20) {
                if version == .draft {
                    JournalEntryToolbar(version: $version, analysis: analysis, voice: voice, choosingVoice: $choosingVoice)
                    JournalPaper(draft: model.draft, reply: nested) {
                        JournalHighlights(segments: result.segments, knownKanji: knownKanji, document: document, sourceID: analysis.id)
                    }
                    if let reply = analysis.currentReply, let feedback = reply.result {
                        JournalPaper(reply: true) {
                            JournalHighlights(segments: feedback.segments, knownKanji: knownKanji, document: document, sourceID: reply.id)
                        }
                    }
                } else {
                    JournalCorrectedView(document: document, analysis: analysis, knownKanji: knownKanji, voice: voice, choosingVoice: $choosingVoice, version: $version, paperReply: nested)
                }
                if followUp { JournalFollowUpView(entry: model, knownKanji: knownKanji).id(analysis.id) }
            }
                .environment(\.journalShowEntries, nested ? nil : showEntries)
                .onChange(of: version) { choosingVoice = false }
        }
    }
}
