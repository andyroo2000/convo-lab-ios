import SwiftUI

struct JournalVersionCopy: View {
    let version: JournalVersion
    let analysis: JournalAnalysis
    @State private var copied = false

    static func text(version: JournalVersion, analysis: JournalAnalysis) -> String {
        if version == .final { return analysis.correctedText ?? "" }
        return [analysis.result, analysis.currentReply?.result].compactMap { $0 }
            .map { $0.segments.map(\.text).joined() }.joined(separator: "\n\n")
    }

    var body: some View {
        Button {
            UIPasteboard.general.string = Self.text(version: version, analysis: analysis)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.accessibilityLabel(copied ? "Copied" : "Copy \(version == .draft ? "draft" : "final") text")
            .onChange(of: version) { copied = false }
            .task(id: copied) {
                guard copied else { return }
                do { try await Task.sleep(for: .seconds(2)); copied = false } catch { }
            }
    }
}
