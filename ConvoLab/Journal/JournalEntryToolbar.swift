import SwiftUI

struct JournalEntryToolbar: View {
    @Binding var version: JournalVersion
    let analysis: JournalAnalysis
    let voice: JournalVoiceSelection
    @Binding var choosingVoice: Bool
    var player: JournalAudioPlayer?
    var listen: () -> Void = {}

    var body: some View {
        HStack(spacing: 4) {
            JournalVersionPicker(selection: $version, compact: true)
            if let player {
                JournalListenButton(player: player, label: "corrected version", disabled: !voice.isReady, toggle: listen)
            }
            Spacer(minLength: 0)
            JournalVersionCopy(version: version, analysis: analysis)
            if version == .final { JournalVoiceButton(voice: voice, choosing: $choosingVoice) }
        }.padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                if let player { JournalRibbonProgress(player: player) }
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Entry controls")
    }
}
