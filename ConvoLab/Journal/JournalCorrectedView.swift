import SwiftUI

struct JournalCorrectedView: View {
    let document: JournalDocumentModel
    let analysis: JournalAnalysis
    let knownKanji: Set<Character>
    let voice: JournalVoiceSelection
    @Binding var choosingVoice: Bool
    @Binding var version: JournalVersion
    var paperReply = false
    @State private var editing = false
    @State private var player = JournalAudioPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if editing {
                JournalEntryToolbar(version: $version, analysis: analysis, voice: voice, choosingVoice: $choosingVoice, edit: beginEditing, editing: true)
                JournalFinalEditor(document: document, analysis: analysis, paperReply: paperReply) { editing = false }
            } else {
                JournalEntryToolbar(version: $version, analysis: analysis, voice: voice, choosingVoice: $choosingVoice, edit: beginEditing)
                VStack(spacing: 0) {
                JournalAudioControls(entryID: document.entry.id, analysis: analysis, service: document.entry.store.service, player: player, voice: voice, choosingVoice: $choosingVoice, version: $version, edit: beginEditing)
                    .id("\(analysis.id):\(analysis.replyRevision ?? 0)").zIndex(1)
                JournalPaper(draft: document.entry.draft, reply: paperReply) {
                    JournalSentenceText(text: analysis.correctedReading ?? "", knownKanji: knownKanji, player: player)
                }
                }
            }
        }
    }

    private func beginEditing() {
        guard !document.disabled, analysis.replyRevision != nil else { return }
        player.stop()
        choosingVoice = false
        document.errorMessage = nil
        editing = true
    }
}
