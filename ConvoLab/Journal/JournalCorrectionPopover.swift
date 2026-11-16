import SwiftUI

struct JournalCorrectionPopover: View {
    let segment: JournalSegment
    let knownKanji: Set<Character>
    let document: JournalDocumentModel?
    let suggestionID: String
    let width: CGFloat
    @ScaledMetric(relativeTo: .footnote) private var statusPointSize: CGFloat = 12

    private var suggestion: JournalCorrectedDocument.Suggestion? {
        document?.entry.analysis?.correctedDocument?.suggestions.first { $0.id == suggestionID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let replacement = segment.replacement {
                VStack(alignment: .leading, spacing: 8) {
                    JournalCorrectionPassage(text: segment.text.isEmpty ? "Insert" : (segment.reading.isEmpty ? segment.text : segment.reading),
                                             original: !segment.text.isEmpty, knownKanji: knownKanji)
                    HStack(alignment: .top) {
                        Text("→").accessibilityHidden(true)
                        JournalCorrectionPassage(text: replacement.isEmpty ? "Remove" : segment.replacementReading ?? replacement,
                                                 original: false, knownKanji: knownKanji)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 0.94, green: 0.92, blue: 0.98), in: .rect(cornerRadius: 8))
                    .accessibilityElement(children: .ignore).accessibilityLabel(editDescription(replacement))
            }
            JournalExplanationText(segment: segment, knownKanji: knownKanji)
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

    private func editDescription(_ replacement: String) -> String {
        if segment.text.isEmpty { return "Insert \(replacement)" }
        if replacement.isEmpty { return "Remove \(segment.text)" }
        return "Replace \(segment.text) with \(replacement)"
    }

    private func status(_ applied: Bool) -> some View {
        Label(applied ? "Applied" : "Original kept", systemImage: applied ? "checkmark" : "arrow.uturn.backward")
            .font(.system(size: statusPointSize)).foregroundStyle(Color(uiColor: JournalPopoverStyle.muted))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("JournalSuggestionStatus")
    }

    private func action(_ suggestion: JournalCorrectedDocument.Suggestion, document: JournalDocumentModel) -> some View {
        Button(label(suggestion.applied)) {
            Task {
                if await document.toggle(suggestion) {
                    UIAccessibility.post(notification: .announcement, argument: suggestion.applied ? "Original kept" : "Applied")
                } else if let error = document.errorMessage {
                    UIAccessibility.post(notification: .announcement, argument: error)
                }
            }
        }.buttonStyle(JournalSuggestionButtonStyle(applied: suggestion.applied)).disabled(document.disabled)
    }

    private func label(_ applied: Bool) -> String {
        if segment.kind == .correction { return applied ? "Reject correction" : "Apply correction" }
        return applied ? "Undo suggestion" : "Apply suggestion"
    }
}
