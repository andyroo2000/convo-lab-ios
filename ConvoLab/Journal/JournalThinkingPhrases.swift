import Foundation

@MainActor
enum JournalThinkingPhrases {
    struct Phrase { let japanese: String; let english: String }
    private static var previous: Int?
    private static let phrases: [Phrase] = [
        Phrase(japanese: "少し待ってくださいね。", english: "Just a moment, please."),
        Phrase(japanese: "ちょっと待ってくださいね。", english: "Give me a moment, please."),
        Phrase(japanese: "少しお待ちくださいね。", english: "Please wait a moment."),
        Phrase(japanese: "少し考えさせてくださいね。", english: "Let me think for a moment."),
        Phrase(japanese: "ちょっと考えますね。", english: "Let me think for a second."),
        Phrase(japanese: "少し時間をくださいね。", english: "Please give me a little time."),
        Phrase(japanese: "ちょっと見てみますね。", english: "Let me take a look."),
        Phrase(japanese: "少し読ませてくださいね。", english: "Let me read through it for a moment."),
    ]
    static func next() -> Phrase {
        let index = phrases.indices.filter { $0 != previous }.randomElement() ?? 0
        previous = index
        return phrases[index]
    }
}
