import SwiftUI

enum StudyReadingSize {
    case character, word, phrase, sentence, passage

    init(_ markup: String) {
        let text = StudyRubyDocument.parse(markup, knownKanji: []).plainText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let japanese = text.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) != nil
        switch (japanese, text.count) {
        case (true, 1): self = .character
        case (true, 2...5): self = .word
        case (false, ...32): self = .phrase
        case (_, ...45): self = .sentence
        default: self = .passage
        }
    }

    var points: CGFloat {
        switch self {
        case .character: 88
        case .word: 54
        case .phrase: 46
        case .sentence: 38
        case .passage: 30
        }
    }

    var alignment: NSTextAlignment {
        switch self {
        case .sentence, .passage: .left
        default: .center
        }
    }
}

struct StudyReadingHeading: View {
    let text: String
    let knownKanji: Set<Character>

    var body: some View {
        let size = StudyReadingSize(text)
        if size == .phrase {
            Text(text)
                .font(.custom("CrimsonPro-Regular", size: size.points, relativeTo: .title))
                .foregroundStyle(StudyWashiStyle.ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        } else {
            StudyRubyText(text, knownKanji: knownKanji, pointSize: size.points,
                          weight: .medium, color: UIColor(StudyWashiStyle.ink), alignment: size.alignment,
                          readingColor: UIColor(StudyWashiStyle.secondaryInk))
        }
    }
}

struct StudyPromptRecording: Hashable {
    let cardID: String
    let url: URL

    var trackID: String { "study-prompt-\(cardID)" }
}

struct StudyReplayGlyph: View {
    let playing: Bool

    var body: some View {
        StudySpeakerIcon(playing: playing)
            .studySpeakerTile(size: 32, playing: playing)
            .accessibilityHidden(true)
    }
}
