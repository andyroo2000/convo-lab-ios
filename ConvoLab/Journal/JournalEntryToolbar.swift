import SwiftUI

struct JournalEntryToolbar: View {
    @Binding var version: JournalVersion
    let analysis: JournalAnalysis
    let voice: JournalVoiceSelection
    @Binding var choosingVoice: Bool
    var edit: (() -> Void)?
    var editing = false
    @State private var showingAppearance = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { JournalEntriesButton().disabled(editing); Spacer(minLength: 0); versions; actions }
            VStack(alignment: .leading, spacing: 6) {
                HStack { JournalEntriesButton().disabled(editing); Spacer(); actions }
                versions
            }
        }.modifier(JournalDeskStyle())
            .outsideDismissibleSheet(isPresented: $showingAppearance) { JournalAppearance() }
            .accessibilityElement(children: .contain).accessibilityLabel("Entry controls")
    }

    private var versions: some View {
        JournalVersionPicker(selection: $version, compact: true).disabled(editing).fixedSize()
    }

    private var actions: some View {
        Menu {
            Button("Copy text", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = JournalVersionCopy.text(version: version, analysis: analysis)
            }
            if let edit { Button("Edit final", systemImage: "pencil", action: edit).disabled(editing) }
            if version == .final && !editing {
                Button("Narration voice", systemImage: "person.wave.2") { choosingVoice = true }
                    .disabled(!voice.isReady).accessibilityIdentifier("JournalVoicePicker")
            }
            Button("Appearance", systemImage: "textformat") { showingAppearance = true }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .accessibilityLabel("More journal options").tint(JournalDeskStyle.green)
    }
}
