import SwiftUI

struct JournalCorrectedView: View {
    let document: JournalDocumentModel
    let analysis: JournalAnalysis
    let knownKanji: Set<Character>
    let voice: JournalVoiceSelection
    @Binding var choosingVoice: Bool
    @Binding var version: JournalVersion
    var paperReply = false
    @State private var player = JournalAudioPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            JournalAudioControls(entryID: document.entry.id, analysis: analysis, service: document.entry.store.service, player: player, voice: voice, choosingVoice: $choosingVoice, version: $version)
                .id("\(analysis.id):\(analysis.replyRevision ?? 0)")
            JournalPaper(draft: document.entry.draft, reply: paperReply) {
                JournalSentenceText(text: analysis.correctedReading ?? "", knownKanji: knownKanji, player: player)
            }
        }
    }
}
