import SwiftUI

struct JournalEntryToolbar: View {
    @Binding var version: JournalVersion
    let analysis: JournalAnalysis
    let voice: JournalVoiceSelection
    @Binding var choosingVoice: Bool
    var edit: (() -> Void)?
    var editing = false
    var player: JournalAudioPlayer?
    var listen: () -> Void = {}

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                JournalVersionPicker(selection: $version, compact: true).disabled(editing).fixedSize()
                Spacer(minLength: 0)
                controls().fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                JournalVersionPicker(selection: $version, compact: true).disabled(editing)
                controls()
            }
        }.padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                if let player { JournalRibbonProgress(player: player) }
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Entry controls")
    }

    private func controls() -> some View {
        HStack(spacing: 4) {
            if let player {
                JournalListenButton(player: player, label: "corrected version", disabled: !voice.isReady, toggle: listen)
            }
            Spacer(minLength: 0)
            JournalVersionCopy(version: version, analysis: analysis)
            if let edit {
                Button(action: edit) { Image(systemName: "pencil") }
                    .buttonStyle(JournalToolbarButtonStyle(outlined: false))
                    .accessibilityLabel("Edit final").disabled(editing)
            }
            if version == .final && !editing { JournalVoiceButton(voice: voice, choosing: $choosingVoice) }
        }
    }

}
