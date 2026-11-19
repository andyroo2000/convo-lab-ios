import SwiftUI

struct JournalEntryToolbar: View {
    @Binding var version: JournalVersion
    let analysis: JournalAnalysis
    let voice: JournalVoiceSelection
    @Binding var choosingVoice: Bool
    var edit: (() -> Void)?
    var editing = false
    @State private var copyID: UUID?

    var body: some View {
        HStack(spacing: 6) { versions; Spacer(minLength: 0); actions }
            .padding(.horizontal, 10).padding(.vertical, 12)
            .background(Color(red: 1, green: 0.992, blue: 0.961), in: UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
            .accessibilityElement(children: .contain).accessibilityLabel("Entry controls")
    }

    private var versions: some View {
        JournalVersionPicker(selection: $version, compact: true).disabled(editing).fixedSize()
    }

    private var actions: some View {
        JournalOptionsMenu {
            JournalOptionButton(title: "Copy text", icon: "doc.on.doc") {
                UIPasteboard.general.string = JournalVersionCopy.text(version: version, analysis: analysis)
                copyID = UUID()
                UIAccessibility.post(notification: .announcement, argument: "Text copied")
            }
            if let edit { JournalOptionButton(title: "Edit final", icon: "pencil", action: edit).disabled(editing) }
            if version == .final && !editing {
                JournalOptionButton(title: "Narration voice", icon: "person.wave.2") { choosingVoice = true }
                    .disabled(!voice.isReady).accessibilityIdentifier("JournalVoicePicker")
            }
        }
            .accessibilityLabel("More journal options").tint(JournalDeskStyle.green)
            .overlay(alignment: .topTrailing) {
                if copyID != nil { JournalCopyToast().alignmentGuide(.top) { $0[.bottom] + 4 } }
            }
            .task(id: copyID) {
                guard copyID != nil else { return }
                do { try await Task.sleep(for: .seconds(2)); copyID = nil } catch { }
            }
            .onChange(of: version) { copyID = nil }
    }
}
