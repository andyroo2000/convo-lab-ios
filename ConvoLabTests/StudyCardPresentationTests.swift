import XCTest
@testable import ConvoLab

@MainActor
final class StudyCardPresentationTests: XCTestCase {
    func testClozePresentationUsesCanonicalMarkupAndRevealsRestoredSentence() {
        let card = makeCard(
            cardType: "cloze",
            prompt: .object([
                "clozeText": .string("毎日運動を{{c1::続けています}}。"),
                "clozeAnswerText": .string("続けています"),
                "clozeDisplayText": .string("毎日運動を[...]続けています。"),
                "clozeResolvedHint": .string("continuously (indicates ongoing action)"),
            ]),
            answer: .object([
                "restoredText": .string("毎日運動を続けています。"),
                "meaning": .string("I exercise every day."),
            ])
        )

        XCTAssertEqual(card.promptText, "毎日運動を[...]。")
        XCTAssertEqual(card.promptHint, "continuously (indicates ongoing action)")
        XCTAssertEqual(card.answerText, "毎日運動を続けています。")
        XCTAssertEqual(card.answerDetailText, "I exercise every day.")
    }

    func testRecognitionPresentationUsesCueAndMeaning() {
        let card = makeCard(
            cardType: "recognition",
            prompt: .object([
                "cueText": .string("先生は知識が豊富ですか？"),
                "cueReading": .string("先生[せんせい]は知識[ちしき]が豊富[ほうふ]ですか？"),
            ]),
            answer: .object([
                "expression": .string("先生は知識が豊富ですか？"),
                "meaning": .string("Is the teacher knowledgeable?"),
            ])
        )

        XCTAssertEqual(card.promptText, "先生は知識が豊富ですか？")
        XCTAssertEqual(card.answerText, "Is the teacher knowledgeable?")
        XCTAssertNil(card.answerDetailText)
    }

    func testReviewIntervalLabelsMatchLearningOSIntervals() {
        XCTAssertEqual(ReviewRating.again.nextIntervalLabel, "<10m")
        XCTAssertEqual(ReviewRating.hard.nextIntervalLabel, "1d")
        XCTAssertEqual(ReviewRating.good.nextIntervalLabel, "3d")
        XCTAssertEqual(ReviewRating.easy.nextIntervalLabel, "7d")
    }

    private func makeCard(
        cardType: String,
        prompt: JSONValue,
        answer: JSONValue
    ) -> StudyCard {
        StudyCard(
            id: "01ky906ejrdqx6ya0j9fvtw5q8",
            noteId: nil,
            cardType: cardType,
            prompt: prompt,
            answer: answer,
            state: .init(
                dueAt: .now,
                introducedAt: .now,
                failedAt: nil,
                queueState: "review",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }
}
