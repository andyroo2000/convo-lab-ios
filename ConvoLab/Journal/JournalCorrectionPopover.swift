import SwiftUI

struct JournalCorrectionPopover: View {
    let segment: JournalSegment
    let knownKanji: Set<Character>
    let document: JournalDocumentModel?
    let suggestionID: String
    let width: CGFloat

    private var suggestion: JournalCorrectedDocument.Suggestion? {
        document?.entry.analysis?.correctedDocument?.suggestions.first { $0.id == suggestionID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StudyRubyText(segment.explanationReading ?? segment.explanation ?? "", knownKanji: knownKanji,
                          pointSize: 14, color: JournalPopoverStyle.ink, alignment: .left, extraLineSpacing: 4)
            if let suggestion, let document {
                Rectangle().fill(Color(uiColor: JournalPopoverStyle.line)).frame(height: 1).accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        status(suggestion.applied)
                        Spacer(minLength: 4)
                        action(suggestion, document: document)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        status(suggestion.applied)
                        action(suggestion, document: document)
                    }
                }
                if let error = document.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            } else {
                Text("To change this passage, edit the corrected version.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).frame(width: width)
            .background(Color(uiColor: JournalPopoverStyle.surface))
            .accessibilityIdentifier("JournalCorrectionPopover")
    }

    private func status(_ applied: Bool) -> some View {
        Label(applied ? "Applied" : "Original kept", systemImage: applied ? "checkmark" : "arrow.uturn.backward")
            .font(.system(size: 12)).foregroundStyle(Color(uiColor: JournalPopoverStyle.muted))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("JournalSuggestionStatus")
    }

    private func action(_ suggestion: JournalCorrectedDocument.Suggestion, document: JournalDocumentModel) -> some View {
        Button(label(suggestion.applied)) {
            Task { _ = await document.toggle(suggestion) }
        }.buttonStyle(JournalSuggestionButtonStyle(applied: suggestion.applied)).disabled(document.disabled)
    }

    private func label(_ applied: Bool) -> String {
        if segment.kind == .correction { return applied ? "Reject correction" : "Apply correction" }
        return applied ? "Undo suggestion" : "Apply suggestion"
    }
}
