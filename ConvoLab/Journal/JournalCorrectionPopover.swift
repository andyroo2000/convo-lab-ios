import SwiftUI

struct JournalCorrectionPopover: View {
    let segment: JournalSegment
    let knownKanji: Set<Character>
    let width: CGFloat
    private let inset: CGFloat = 14
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let replacement = segment.replacement {
                JournalCorrectionPassage(text: segment.text.isEmpty ? "Insert" : (segment.reading.isEmpty ? segment.text : segment.reading),
                                         original: !segment.text.isEmpty, knownKanji: knownKanji,
                                         replacement: replacement.isEmpty ? "Remove" : segment.replacementReading ?? replacement)
                    .frame(width: width - 2 * inset)
                    .padding(.horizontal, inset).padding(.vertical, 10).frame(width: width, alignment: .leading)
                    .background(Color(red: 0.937, green: 0.925, blue: 0.969))
                    .accessibilityElement(children: .ignore).accessibilityLabel(editDescription(replacement))
            }
            JournalExplanationText(segment: segment, knownKanji: knownKanji).frame(width: width - 2 * inset)
                .padding(.horizontal, inset).padding(.top, 6).padding(.bottom, 12)
        }.frame(width: width)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: JournalPopoverBackground.cornerRadius, style: .circular))
            .environment(\.colorScheme, .light)
            .accessibilityIdentifier("JournalCorrectionPopover")
    }

    private func editDescription(_ replacement: String) -> String {
        if segment.text.isEmpty { return "Insert \(replacement)" }
        if replacement.isEmpty { return "Remove \(segment.text)" }
        return "Replace \(segment.text) with \(replacement)"
    }

}
