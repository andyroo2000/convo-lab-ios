import SwiftUI

struct JournalFeedbackView: View {
    let model: JournalEntryModel
    let knownKanji: Set<Character>
    var body: some View {
        if let analysis = model.analysis, let result = analysis.result {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(JournalDates.display(model.draft?.entryDate ?? "")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit entry") { model.isEditing = true }
                }
                Text(model.draft?.title ?? "Untitled entry").font(.largeTitle.bold()).foregroundStyle(ConvoLabTheme.navy)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { legend }
                    VStack(alignment: .leading, spacing: 6) { legend }
                }.font(.caption)
                JournalHighlights(segments: result.segments, knownKanji: knownKanji)
                Divider()
                HStack {
                    Text("Corrected Version").font(.headline)
                    Spacer()
                    Button("Copy") { UIPasteboard.general.string = analysis.correctedText }
                }
                JournalAudioControls(entryID: model.id, analysis: analysis, service: model.store.service)
                    .id("\(analysis.id):\(analysis.replyRevision ?? 0)")
                StudyRubyText(analysis.correctedReading ?? "", knownKanji: knownKanji, pointSize: 20, alignment: .left)
            }
        }
    }
    private var legend: some View {
        Group {
            Text("Correction").underline(pattern: .solid, color: .red)
            Text("Optional change").underline(pattern: .dash, color: .orange)
            Text("Worth keeping").underline(pattern: .dot, color: .green)
        }
    }
}
