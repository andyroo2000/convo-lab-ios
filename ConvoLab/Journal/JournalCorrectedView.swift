import SwiftUI

struct JournalCorrectedView: View {
    let document: JournalDocumentModel
    let analysis: JournalAnalysis
    let knownKanji: Set<Character>
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !compact { Text("Corrected Version").font(.headline) }
            JournalAudioControls(entryID: document.entry.id, analysis: analysis, service: document.entry.store.service)
                .id("\(analysis.id):\(analysis.replyRevision ?? 0)")
            JournalRubyText(text: analysis.correctedReading ?? "", knownKanji: knownKanji)
        }
    }
}
