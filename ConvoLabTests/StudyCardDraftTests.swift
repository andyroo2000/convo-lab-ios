import XCTest
@testable import ConvoLab

final class StudyCardDraftTests: XCTestCase {
    @MainActor
    func testClozeDraftReadsAndWritesTypeSpecificFieldsWhilePreservingMedia() {
        let card = makeCard(
            cardType: "cloze",
            prompt: .object([
                "clozeText": .string("毎日{{c1::勉強する}}。"),
                "clozeHint": .string("daily habit"),
                "cueImage": media("/media/prompt.png"),
            ]),
            answer: .object([
                "restoredText": .string("毎日勉強する。"),
                "restoredTextReading": .string("毎日[まいにち]勉強[べんきょう]する。"),
                "meaning": .string("I study every day."),
                "notes": .string("Keep going."),
                "answerAudio": media("/media/answer.mp3"),
            ])
        )

        var draft = StudyCardDraft(card: card)
        XCTAssertEqual(draft.cardType, .cloze)
        XCTAssertEqual(draft.cueText, "毎日{{c1::勉強する}}。")
        XCTAssertEqual(draft.answerExpression, "毎日勉強する。")

        draft.answerMeaning = "Study every day."
        let prompt = draft.prompt(merging: card.prompt)
        let answer = draft.answer(merging: card.answer)

        XCTAssertEqual(prompt["cueImage"], card.prompt["cueImage"])
        XCTAssertEqual(answer["answerAudio"], card.answer["answerAudio"])
        XCTAssertEqual(answer["meaning"]?.stringValue, "Study every day.")
        XCTAssertEqual(
            answer["restoredTextReading"]?.stringValue,
            "毎日[まいにち]勉強[べんきょう]する。"
        )
    }

    @MainActor
    func testEditingResolvedClozeHintMakesNewHintVisible() {
        let card = makeCard(
            cardType: "cloze",
            prompt: .object([
                "clozeText": .string("毎日{{c1::勉強する}}。"),
                "clozeHint": .string("old manual hint"),
                "clozeResolvedHint": .string("old resolved hint"),
            ]),
            answer: .object([
                "restoredText": .string("毎日勉強する。"),
                "meaning": .string("I study every day."),
            ])
        )
        var draft = StudyCardDraft(card: card)
        XCTAssertEqual(draft.cueMeaning, "old resolved hint")
        draft.cueMeaning = "new hint"
        let prompt = draft.prompt(merging: card.prompt)
        let updated = StudyCard(
            id: card.id,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: prompt,
            answer: card.answer,
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: card.updatedAt
        )

        XCTAssertEqual(prompt["clozeHint"], .string("new hint"))
        XCTAssertEqual(prompt["clozeResolvedHint"], .null)
        XCTAssertEqual(updated.presentation.front.supportingText, "new hint")
    }

    @MainActor
    func testClozeDraftRequiresCompleteCanonicalMarkup() {
        var draft = StudyCardDraft(cardType: .cloze)
        draft.answerExpression = "毎日勉強する。"

        draft.cueText = "毎日勉強する。"
        XCTAssertFalse(draft.hasCanonicalClozeMarkup)
        XCTAssertFalse(draft.isValid)

        draft.cueText = "毎日{{c1::勉強する"
        XCTAssertFalse(draft.hasCanonicalClozeMarkup)
        XCTAssertFalse(draft.isValid)

        draft.cueText = "毎日{{c1::勉強する}}。"
        XCTAssertTrue(draft.hasCanonicalClozeMarkup)
        XCTAssertTrue(draft.isValid)
    }

    @MainActor
    func testProductionDraftPreservesServerManagedPayloadAndClearsOptionalText() {
        let card = makeCard(
            cardType: "production",
            prompt: .object([
                "cueText": .string("会社"),
                "cueReading": .string("会社[かいしゃ]"),
                "cueMeaning": .string("company"),
                "cueAudio": media("/media/prompt.mp3"),
            ]),
            answer: .object([
                "expression": .string("会社で働く。"),
                "expressionReading": .string("会社[かいしゃ]で働[はたら]く。"),
                "meaning": .string("Work at a company."),
                "pitchAccent": .object(["status": .string("resolved")]),
            ])
        )

        var draft = StudyCardDraft(card: card)
        draft.cueMeaning = ""
        draft.sentenceJapanese = "会社で毎日働く。"
        let prompt = draft.prompt(merging: card.prompt)
        let answer = draft.answer(merging: card.answer)

        XCTAssertEqual(draft.cardType, .production)
        XCTAssertEqual(prompt["cueMeaning"], .null)
        XCTAssertEqual(prompt["cueAudio"], card.prompt["cueAudio"])
        XCTAssertEqual(answer["pitchAccent"], card.answer["pitchAccent"])
        XCTAssertEqual(answer["sentenceJp"]?.stringValue, "会社で毎日働く。")
    }

    @MainActor
    func testMediaLedDraftCanSaveWithoutCueTextAndPreservesPromptMedia() {
        let card = makeCard(
            cardType: "recognition",
            prompt: .object([
                "cueAudio": media("/media/prompt.mp3"),
            ]),
            answer: .object([
                "expression": .string("続けています"),
                "meaning": .string("I keep doing it."),
            ])
        )

        let draft = StudyCardDraft(card: card)
        let prompt = draft.prompt(merging: card.prompt)

        XCTAssertTrue(draft.isMediaLedPrompt)
        XCTAssertTrue(draft.isAudioLedPrompt)
        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(prompt["cueText"], .null)
        XCTAssertEqual(prompt["cueMeaning"], .null)
        XCTAssertEqual(prompt["cueAudio"], card.prompt["cueAudio"])
    }

    @MainActor
    func testAudioLedProductionRoundTripMatchesDesktopEditorContract() {
        let card = makeCard(
            cardType: "production",
            prompt: .object([
                "cueAudio": media("/media/production-prompt.mp3"),
            ]),
            answer: .object([
                "expression": .string("続けています"),
                "meaning": .string("I keep doing it."),
            ])
        )

        let draft = StudyCardDraft(card: card)
        let prompt = draft.prompt(merging: card.prompt)

        XCTAssertTrue(draft.isMediaLedPrompt)
        XCTAssertFalse(draft.isAudioLedPrompt)
        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(prompt["cueText"], .string(""))
        XCTAssertEqual(prompt["cueReading"], .null)
        XCTAssertEqual(prompt["cueMeaning"], .null)
        XCTAssertEqual(prompt["cueAudio"], card.prompt["cueAudio"])
    }

    @MainActor
    func testImageLedProductionKeepsVisibleLabelAndAllowsEmptyCueText() {
        let card = makeCard(
            cardType: "production",
            prompt: .object([
                "cueImage": media("/media/prompt.png"),
                "cueMeaning": .string("名詞"),
            ]),
            answer: .object([
                "expression": .string("教材"),
                "meaning": .string("study materials"),
            ])
        )

        let draft = StudyCardDraft(card: card)
        let prompt = draft.prompt(merging: card.prompt)

        XCTAssertTrue(draft.isMediaLedPrompt)
        XCTAssertFalse(draft.isAudioLedPrompt)
        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(prompt["cueMeaning"], .string("名詞"))
        XCTAssertEqual(prompt["cueImage"], card.prompt["cueImage"])
    }

    @MainActor
    func testDraftPreservesUnexpectedNonStringKnownFieldsWhenUntouched() {
        let card = makeCard(
            cardType: "recognition",
            prompt: .object([
                "cueText": .string("教材"),
                "cueMeaning": .array([.string("unexpected")]),
            ]),
            answer: .object([
                "expression": .string("教材"),
                "meaning": .string("study materials"),
                "notes": .object(["legacy": .bool(true)]),
            ])
        )

        let draft = StudyCardDraft(card: card)

        XCTAssertEqual(
            draft.prompt(merging: card.prompt)["cueMeaning"],
            card.prompt["cueMeaning"]
        )
        XCTAssertEqual(
            draft.answer(merging: card.answer)["notes"],
            card.answer["notes"]
        )
    }

    @MainActor
    private func makeCard(
        cardType: String,
        prompt: JSONValue,
        answer: JSONValue
    ) -> StudyCard {
        StudyCard(
            id: "01J000000000000000000000DR",
            noteId: nil,
            cardType: cardType,
            prompt: prompt,
            answer: answer,
            state: .init(
                dueAt: nil,
                introducedAt: nil,
                failedAt: nil,
                queueState: "new",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "generated",
            createdAt: .now,
            updatedAt: .now
        )
    }

    private func media(_ url: String) -> JSONValue {
        .object([
            "url": .string(url),
            "filename": .string(URL(string: url)?.lastPathComponent ?? "media"),
        ])
    }
}
