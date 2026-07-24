import XCTest
@testable import ConvoLab

final class StudyCardDraftTests: XCTestCase {
    @MainActor
    func testCreationKindsMatchDesktopCardTypesAndImageDefaults() {
        XCTAssertEqual(StudyCardCreationKind.textRecognition.cardType, .recognition)
        XCTAssertEqual(StudyCardCreationKind.audioRecognition.cardType, .recognition)
        XCTAssertEqual(StudyCardCreationKind.productionText.cardType, .production)
        XCTAssertEqual(StudyCardCreationKind.productionImage.cardType, .production)
        XCTAssertEqual(StudyCardCreationKind.cloze.cardType, .cloze)
        XCTAssertEqual(StudyCardCreationKind.textRecognition.defaultImagePlacement, .none)
        XCTAssertEqual(StudyCardCreationKind.audioRecognition.defaultImagePlacement, .none)
        XCTAssertEqual(StudyCardCreationKind.productionText.defaultImagePlacement, .none)
        XCTAssertEqual(StudyCardCreationKind.productionImage.defaultImagePlacement, .prompt)
        XCTAssertEqual(StudyCardCreationKind.cloze.defaultImagePlacement, .both)
    }

    @MainActor
    func testImageProductionRequiresAPromptBeforePreparation() {
        var draft = StudyCardDraft(cardType: .production)
        draft.isMediaLedPrompt = true
        draft.answerExpression = "会社"
        draft.imagePlacement = .prompt

        XCTAssertTrue(draft.isValid)
        XCTAssertFalse(draft.isValid(for: .productionImage))

        draft.imagePrompt = "A Japanese company office"

        XCTAssertTrue(draft.isValid(for: .productionImage))
    }

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
        let untouchedPrompt = draft.prompt(merging: card.prompt)
        XCTAssertEqual(untouchedPrompt["clozeHint"], .string("old manual hint"))
        XCTAssertEqual(untouchedPrompt["clozeResolvedHint"], .string("old resolved hint"))

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
        XCTAssertNil(draft.prompt()["clozeResolvedHint"])
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
                // Desktop treats a reading without cue text as orphaned prompt
                // metadata and clears all hidden text fields on save.
                "cueReading": .string("続[つづ]けています"),
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
        XCTAssertEqual(prompt["cueReading"], .null)
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
    func testAnswerAudioSettingsRoundTripAndDefaultToDesktopVoice() {
        let existing = makeCard(
            cardType: "cloze",
            prompt: .object(["clozeText": .string("{{c1::会社}}です。")]),
            answer: .object([
                "restoredText": .string("会社です。"),
                "answerAudioVoiceId": .string(
                    "fishaudio:875668667eb94c20b09856b971d9ca2f"
                ),
                "answerAudioTextOverride": .string("かいしゃ"),
            ])
        )
        var draft = StudyCardDraft(card: existing)

        XCTAssertEqual(
            draft.answerAudioVoiceId,
            "fishaudio:875668667eb94c20b09856b971d9ca2f"
        )
        XCTAssertEqual(draft.answerAudioTextOverride, "かいしゃ")

        draft.answerAudioTextOverride = ""
        let answer = draft.answer(merging: existing.answer)
        XCTAssertEqual(
            answer["answerAudioVoiceId"],
            .string("fishaudio:875668667eb94c20b09856b971d9ca2f")
        )
        XCTAssertEqual(answer["answerAudioTextOverride"], .null)

        XCTAssertEqual(
            StudyCardDraft().answerAudioVoiceId,
            StudyAnswerVoice.defaultVoice.id
        )
    }

    @MainActor
    func testImagePlacementMovesOneImageBetweenCardFaces() {
        let image = media("/media/company.webp")
        let card = makeCard(
            cardType: "recognition",
            prompt: .object([
                "cueText": .string("会社"),
                "cueImage": image,
            ]),
            answer: .object([
                "expression": .string("会社"),
                "meaning": .string("company"),
            ])
        )
        var draft = StudyCardDraft(card: card)

        XCTAssertEqual(draft.imagePlacement, .prompt)
        XCTAssertEqual(draft.currentImage, image)
        XCTAssertEqual(
            draft.imagePrompt,
            "A clear natural real-world image representing 会社 (company)."
        )

        draft.imagePlacement = .both
        XCTAssertEqual(draft.prompt(merging: card.prompt)["cueImage"], image)
        XCTAssertEqual(draft.answer(merging: card.answer)["answerImage"], image)

        draft.imagePlacement = .answer
        XCTAssertEqual(draft.prompt(merging: card.prompt)["cueImage"], .null)
        XCTAssertEqual(draft.answer(merging: card.answer)["answerImage"], image)

        draft.imagePlacement = .none
        XCTAssertEqual(draft.prompt(merging: card.prompt)["cueImage"], .null)
        XCTAssertEqual(draft.answer(merging: card.answer)["answerImage"], .null)
    }

    @MainActor
    func testUntouchedSavePreservesIndependentFrontAndBackImages() {
        let frontImage = media("/media/front.webp")
        let backImage = media("/media/back.webp")
        let card = makeCard(
            cardType: "recognition",
            prompt: .object([
                "cueText": .string("会社"),
                "cueImage": frontImage,
            ]),
            answer: .object([
                "expression": .string("会社"),
                "meaning": .string("company"),
                "answerImage": backImage,
            ])
        )
        var draft = StudyCardDraft(card: card)
        draft.answerMeaning = "a business"

        XCTAssertEqual(draft.imagePlacement, .both)
        XCTAssertEqual(draft.prompt(merging: card.prompt)["cueImage"], frontImage)
        XCTAssertEqual(draft.answer(merging: card.answer)["answerImage"], backImage)

        // An explicit placement change opts into the desktop single-image model.
        draft.imagePlacement = .prompt
        XCTAssertEqual(draft.prompt(merging: card.prompt)["cueImage"], frontImage)
        XCTAssertEqual(draft.answer(merging: card.answer)["answerImage"], .null)

        // Choosing the back face keeps the image that was already on that face.
        draft = StudyCardDraft(card: card)
        draft.imagePlacement = .answer
        XCTAssertEqual(draft.prompt(merging: card.prompt)["cueImage"], .null)
        XCTAssertEqual(draft.answer(merging: card.answer)["answerImage"], backImage)
        XCTAssertTrue(draft.isReplacingIndependentFaceImages)

        draft.imagePlacement = .both
        XCTAssertEqual(draft.prompt(merging: card.prompt)["cueImage"], frontImage)
        XCTAssertEqual(draft.answer(merging: card.answer)["answerImage"], frontImage)

        draft.reconcileImages(promptImage: frontImage, answerImage: backImage)
        XCTAssertEqual(draft.imagePlacement, .both)
        XCTAssertTrue(draft.hasIndependentFaceImages)
        XCTAssertFalse(draft.isReplacingIndependentFaceImages)
        XCTAssertEqual(draft.prompt(merging: card.prompt)["cueImage"], frontImage)
        XCTAssertEqual(draft.answer(merging: card.answer)["answerImage"], backImage)
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
