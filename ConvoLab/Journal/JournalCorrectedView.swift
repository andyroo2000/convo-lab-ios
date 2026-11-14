import SwiftUI

struct JournalCorrectedView: View {
    let document: JournalDocumentModel
    let analysis: JournalAnalysis
    let knownKanji: Set<Character>
    let voice: JournalVoiceSelection
    @Binding var choosingVoice: Bool
    var compact = false
    @State private var player = JournalAudioPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !compact { Text("Corrected Version").font(.headline) }
            JournalAudioControls(entryID: document.entry.id, analysis: analysis, service: document.entry.store.service, player: player, voice: voice, choosingVoice: $choosingVoice)
                .id("\(analysis.id):\(analysis.replyRevision ?? 0)")
            JournalSentenceText(text: analysis.correctedReading ?? "", knownKanji: knownKanji, player: player)
        }
    }
}
