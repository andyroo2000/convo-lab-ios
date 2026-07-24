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
        XCTAssertEqual(card.presentation.front.heading, "毎日運動を[...]。")
        XCTAssertEqual(
            card.presentation.front.supportingText,
            "continuously (indicates ongoing action)"
        )
        XCTAssertEqual(card.presentation.back.heading, "毎日運動を続けています。")
        XCTAssertEqual(card.presentation.back.textBlocks.map(\.text), ["I exercise every day."])
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
        XCTAssertEqual(card.presentation.front.heading, "先生は知識が豊富ですか？")
        XCTAssertEqual(
            card.presentation.back.heading,
            "先生は知識が豊富ですか？"
        )
        XCTAssertEqual(
            card.presentation.back.textBlocks.map(\.role),
            [.meaning]
        )
        XCTAssertTrue(card.isEditableInBasicForm)
    }

    func testAnswerDetailsFollowDesktopOrderAndDecodePlainText() {
        let card = makeCard(
            cardType: "recognition",
            prompt: .object(["cueText": .string("会社")]),
            answer: .object([
                "expression": .string("会社"),
                "expressionReading": .string("会社[かいしゃ]"),
                "restoredText": .string("会社で働く"),
                "meaning": .string("It&#x27;s a company."),
                "sentenceJp": .string("会社で働いています。"),
                "sentenceEn": .string("I work at a company."),
                "notes": .string("<p>First note.</p><p>Second note.</p>"),
            ])
        )

        XCTAssertEqual(card.presentation.back.heading, "会社[かいしゃ]")
        XCTAssertEqual(
            card.presentation.back.textBlocks.map(\.role),
            [.restoredText, .meaning, .sentenceJapanese, .sentenceEnglish, .note, .note]
        )
        XCTAssertEqual(
            card.presentation.back.textBlocks.map(\.text),
            [
                "会社で働く",
                "It's a company.",
                "会社で働いています。",
                "I work at a company.",
                "First note.",
                "Second note.",
            ]
        )
    }

    func testMediaLedPromptHidesHelperMeaning() {
        let card = makeCard(
            cardType: "recognition",
            prompt: .object([
                "cueAudio": media(url: "https://example.com/prompt.mp3", kind: "audio"),
                "cueImage": media(url: "https://example.com/prompt.png", kind: "image"),
                "cueMeaning": .string("hidden helper meaning"),
            ]),
            answer: .object([
                "expression": .string("事故です。"),
                "meaning": .string("It's an accident."),
            ])
        )

        XCTAssertTrue(card.presentation.front.isMediaLed)
        XCTAssertNil(card.presentation.front.heading)
        XCTAssertNil(card.presentation.front.supportingText)
        XCTAssertEqual(
            card.presentation.front.audioURL,
            URL(string: "https://example.com/prompt.mp3")
        )
        XCTAssertEqual(
            card.presentation.front.imageURL,
            URL(string: "https://example.com/prompt.png")
        )
        XCTAssertFalse(card.isEditableInBasicForm)
    }

    func testImageOnlyProductionPromptShowsDesktopPartOfSpeechLabel() {
        let card = makeCard(
            cardType: "production",
            prompt: .object([
                "cueImage": media(url: "/study/cloudy.png", kind: "image"),
                "cueMeaning": .string("名詞"),
            ]),
            answer: .object([
                "expression": .string("曇り"),
                "meaning": .string("cloudy"),
            ])
        )

        XCTAssertTrue(card.presentation.front.isMediaLed)
        XCTAssertNil(card.presentation.front.heading)
        XCTAssertEqual(card.presentation.front.supportingText, "名詞")
        XCTAssertEqual(card.presentation.front.imageURL, URL(string: "/study/cloudy.png"))
    }

    func testClozeOnlyBlanksFirstOrdinalAndRestoresAllAnswers() {
        let card = makeCard(
            cardType: "cloze",
            prompt: .object([
                "clozeText": .string("{{c1::今日}}は{{c2::雨}}です。"),
            ]),
            answer: .object([:])
        )

        XCTAssertEqual(card.presentation.front.heading, "[...]は雨です。")
        XCTAssertEqual(card.presentation.back.heading, "今日は雨です。")
        XCTAssertFalse(card.isEditableInBasicForm)
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

    private func media(url: String, kind: String) -> JSONValue {
        .object([
            "filename": .string(URL(string: url)?.lastPathComponent ?? "media"),
            "url": .string(url),
            "mediaKind": .string(kind),
            "source": .string("imported"),
        ])
    }
}
