import SwiftUI

struct JournalCorrectionPopover: View {
    let segment: JournalSegment
    let knownKanji: Set<Character>
    let width: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let replacement = segment.replacement {
                VStack(alignment: .leading, spacing: 8) {
                    JournalCorrectionPassage(text: segment.text.isEmpty ? "Insert" : (segment.reading.isEmpty ? segment.text : segment.reading),
                                             original: !segment.text.isEmpty, knownKanji: knownKanji).frame(width: width - 28)
                    HStack(alignment: .top) {
                        Text("→").accessibilityHidden(true)
                        JournalCorrectionPassage(text: replacement.isEmpty ? "Remove" : segment.replacementReading ?? replacement,
                                                 original: false, knownKanji: knownKanji).frame(width: width - 60)
                    }
                }.padding(14).frame(width: width, alignment: .leading)
                    .background(Color(red: 0.94, green: 0.92, blue: 0.98))
                    .accessibilityElement(children: .ignore).accessibilityLabel(editDescription(replacement))
            }
            JournalExplanationText(segment: segment, knownKanji: knownKanji).frame(width: width - 28).padding(14)
        }.frame(width: width)
            .background(.white)
            .environment(\.colorScheme, .light)
            .accessibilityIdentifier("JournalCorrectionPopover")
    }

    private func editDescription(_ replacement: String) -> String {
        if segment.text.isEmpty { return "Insert \(replacement)" }
        if replacement.isEmpty { return "Remove \(segment.text)" }
        return "Replace \(segment.text) with \(replacement)"
    }

}
