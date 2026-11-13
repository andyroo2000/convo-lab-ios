import SwiftUI

struct JournalFeedbackView: View {
    let model: JournalEntryModel
    let knownKanji: Set<Character>
    @State private var document: JournalDocumentModel

    init(model: JournalEntryModel, knownKanji: Set<Character>) {
        self.model = model
        self.knownKanji = knownKanji
        _document = State(initialValue: JournalDocumentModel(entry: model))
    }
    var body: some View {
        if let analysis = model.analysis, let result = analysis.result {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(JournalDates.display(model.draft?.entryDate ?? "")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit entry") { model.isEditing = true }
                }
                Text(model.draft?.title ?? "Untitled entry").font(.largeTitle.bold()).foregroundStyle(Color(uiColor: JournalPopoverStyle.ink))
                JournalHighlights(segments: result.segments, knownKanji: knownKanji, document: document, sourceID: analysis.id)
                if let reply = analysis.currentReply, let feedback = reply.result {
                    Text("Your last answer").font(.subheadline).foregroundStyle(.secondary)
                    JournalHighlights(segments: feedback.segments, knownKanji: knownKanji, document: document, sourceID: reply.id)
                }
                if (result.segments + (analysis.currentReply?.result?.segments ?? [])).contains(where: { $0.kind.isHighlighted }) {
                    JournalHighlightLegend()
                }
                Divider()
                JournalCorrectedView(document: document, analysis: analysis, knownKanji: knownKanji)
                JournalFollowUpView(entry: model, knownKanji: knownKanji).id(analysis.id)
            }
        }
    }
}
