import SwiftUI

struct JournalCorrectionPopover: View {
    let segment: JournalSegment
    let knownKanji: Set<Character>
    let document: JournalDocumentModel?
    let suggestionID: String
    let width: CGFloat
    @Environment(\.dismiss) private var dismiss

    private var suggestion: JournalCorrectedDocument.Suggestion? {
        document?.entry.analysis?.correctedDocument?.suggestions.first { $0.id == suggestionID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StudyRubyText(segment.explanationReading ?? segment.explanation ?? "", knownKanji: knownKanji,
                          pointSize: 14, color: .secondaryLabel, alignment: .left)
            if let suggestion, let document {
                Button(label(suggestion.applied)) {
                    Task { if await document.toggle(suggestion) { dismiss() } }
                }.buttonStyle(.bordered).disabled(document.disabled)
                if let error = document.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            } else {
                Text("To change this passage, edit the corrected version.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).frame(width: width).accessibilityIdentifier("JournalCorrectionPopover")
    }

    private func label(_ applied: Bool) -> String {
        if segment.kind == .correction { return applied ? "Reject correction" : "Apply correction" }
        return applied ? "Undo suggestion" : "Apply suggestion"
    }
}
