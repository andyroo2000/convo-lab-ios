import SwiftUI

struct JournalEntryToolbar: View {
    @Binding var version: JournalVersion
    let analysis: JournalAnalysis
    let voice: JournalVoiceSelection
    @Binding var choosingVoice: Bool
    var edit: (() -> Void)?
    var editing = false
    @State private var showingAppearance = false
    @State private var showingKeyboard = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { JournalEntriesButton().disabled(editing); Spacer(minLength: 0); versions; actions }
            VStack(alignment: .leading, spacing: 6) {
                HStack { JournalEntriesButton().disabled(editing); Spacer(); actions }
                versions
            }
        }.modifier(JournalDeskStyle())
            .outsideDismissibleSheet(isPresented: $showingAppearance) { JournalAppearance() }
            .sheet(isPresented: $showingKeyboard) { JournalKeyboardSheet() }
            .accessibilityElement(children: .contain).accessibilityLabel("Entry controls")
    }

    private var versions: some View {
        JournalVersionPicker(selection: $version, compact: true).disabled(editing).fixedSize()
    }

    private var actions: some View {
        JournalOptionsMenu {
            JournalOptionButton(title: "Copy text", icon: "doc.on.doc") {
                UIPasteboard.general.string = JournalVersionCopy.text(version: version, analysis: analysis)
            }
            if let edit { JournalOptionButton(title: "Edit final", icon: "pencil", action: edit).disabled(editing) }
            if version == .final && !editing {
                JournalOptionButton(title: "Narration voice", icon: "person.wave.2") { choosingVoice = true }
                    .disabled(!voice.isReady).accessibilityIdentifier("JournalVoicePicker")
            }
            JournalOptionButton(title: "Appearance", icon: "textformat") { showingAppearance = true }
            JournalKeyboardMenuItem { showingKeyboard = true }
        }
            .accessibilityLabel("More journal options").tint(JournalDeskStyle.green)
    }
}
