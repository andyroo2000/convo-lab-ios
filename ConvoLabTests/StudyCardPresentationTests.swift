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
        XCTAssertEqual(
            card.presentation.front.heading,
            "先生[せんせい]は知識[ちしき]が豊富[ほうふ]ですか？"
        )
        XCTAssertEqual(
            card.presentation.back.heading,
            "先生[せんせい]は知識[ちしき]が豊富[ほうふ]ですか？"
        )
        XCTAssertEqual(
            card.presentation.back.textBlocks.map(\.role),
            [.meaning]
        )
        XCTAssertTrue(card.isEditableInBasicForm)
    }

    func testRecognitionFrontIgnoresReadingForDifferentCueText() {
        let card = makeCard(
            cardType: "recognition",
            prompt: .object([
                "cueText": .string("先生"),
                "cueReading": .string("学生[がくせい]"),
            ]),
            answer: .object([
                "expressionReading": .string("会社[かいしゃ]"),
            ])
        )

        XCTAssertEqual(card.presentation.front.heading, "先生")
    }

    func testClozeFrontPreservesRubyOutsideMaskedAnswer() {
        let card = makeCard(
            cardType: "cloze",
            prompt: .object([
                "clozeText": .string("会社で{{c1::働く}}"),
            ]),
            answer: .object([
                "restoredText": .string("会社で働く"),
                "restoredTextReading": .string("会社[かいしゃ]で働[はたら]く"),
            ])
        )

        XCTAssertEqual(card.presentation.front.heading, "会社[かいしゃ]で[...]")
        XCTAssertEqual(card.presentation.back.heading, "会社[かいしゃ]で働[はたら]く")
        XCTAssertEqual(card.promptText, "会社で[...]")
        XCTAssertEqual(card.answerText, "会社で働く")
    }

    func testClozeFrontNeverRevealsMultipleSameOrdinalAnswersThroughRuby() {
        let card = makeCard(
            cardType: "cloze",
            prompt: .object([
                "clozeText": .string("{{c1::春}}に花が{{c1::咲く}}。"),
            ]),
            answer: .object([
                "restoredText": .string("春に花が咲く。"),
                "restoredTextReading": .string("春[はる]に花[はな]が咲[さ]く。"),
            ])
        )

        XCTAssertEqual(card.presentation.front.heading, "[...]に花が[...]。")
        XCTAssertFalse(card.presentation.front.heading?.contains("はる") == true)
        XCTAssertFalse(card.presentation.front.heading?.contains("さ") == true)
    }

    func testClozeFrontPreservesKanjiAdjacentBlankMarker() {
        let card = makeCard(
            cardType: "cloze",
            prompt: .object([
                "clozeText": .string("日本{{c1::語}}を勉強する"),
            ]),
            answer: .object([
                "restoredText": .string("日本語を勉強する"),
                "restoredTextReading": .string("日本語[にほんご]を勉強[べんきょう]する"),
            ])
        )

        let heading = card.presentation.front.heading
        XCTAssertEqual(heading, "日本[...]を勉強[べんきょう]する")
        XCTAssertEqual(
            StudyRubyDocument.parse(heading ?? "", knownKanji: []).plainText,
            "日本[...]を勉強する"
        )
    }

    func testClozeFrontFallsBackWhenReadingDoesNotAlign() {
        let card = makeCard(
            cardType: "cloze",
            prompt: .object([
                "clozeText": .string("会社で{{c1::働く}}"),
            ]),
            answer: .object([
                "restoredText": .string("会社で働く"),
                "restoredTextReading": .string("学生[がくせい]"),
            ])
        )

        XCTAssertEqual(card.presentation.front.heading, "会社で[...]")
    }

    func testClozeFrontFallsBackWhenPrefixAndSuffixWouldOverlap() {
        let card = makeCard(
            cardType: "cloze",
            prompt: .object([
                "clozeText": .string("AB{{c1::X}}B"),
            ]),
            answer: .object([
                "restoredText": .string("AB"),
                "restoredTextReading": .string("AB"),
            ])
        )

        XCTAssertEqual(card.presentation.front.heading, "AB[...]B")
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
        XCTAssertEqual(card.promptText, "事故です。")
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

    func testImageOnlyRecognitionPromptHidesPartOfSpeechHelper() {
        let card = makeCard(
            cardType: "recognition",
            prompt: .object([
                "cueImage": media(url: "/study/cat.png", kind: "image"),
                "cueMeaning": .string("名詞"),
            ]),
            answer: .object([
                "expression": .string("猫"),
            ])
        )

        XCTAssertTrue(card.presentation.front.isMediaLed)
        XCTAssertNil(card.presentation.front.supportingText)
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

    func testLooseDisplayOnlyClozeDoesNotExposeAnswer() {
        let card = makeCard(
            cardType: "cloze",
            prompt: .object([
                "clozeDisplayText": .string("私は[学生]です。"),
            ]),
            answer: .object([
                "restoredText": .string("私は学生です。"),
                "meaning": .string("I am a student."),
            ])
        )

        XCTAssertEqual(card.presentation.front.heading, "私は[...]です。")
        XCTAssertEqual(card.presentation.back.heading, "私は学生です。")
    }

    func testLooseClozeSkipsFuriganaBracketsBeforeAnswer() {
        let card = makeCard(
            cardType: "cloze",
            prompt: .object([
                "clozeDisplayText": .string("彼[かれ]は[医者]です。"),
                "clozeHint": .string("occupation"),
            ]),
            answer: .object([
                "restoredText": .string("彼は医者です。"),
            ])
        )

        XCTAssertEqual(card.presentation.front.heading, "彼[かれ]は[...]です。")
        XCTAssertEqual(card.presentation.front.supportingText, "occupation")
        XCTAssertEqual(card.presentation.back.heading, "彼は医者です。")
    }

    func testLooseClozeBlanksEveryAnswerAndPreservesFurigana() {
        let card = makeCard(
            cardType: "cloze",
            prompt: .object([
                "clozeDisplayText": .string("私[わたし]は[学生]で、彼[かれ]は[医者]です。"),
            ]),
            answer: .object([:])
        )

        XCTAssertEqual(
            card.presentation.front.heading,
            "私[わたし]は[...]で、彼[かれ]は[...]です。"
        )
        XCTAssertEqual(
            card.presentation.back.heading,
            "私[わたし]は学生で、彼[かれ]は医者です。"
        )
    }

    func testMalformedCardUsesHonestLibraryFallback() {
        let card = makeCard(
            cardType: "cloze",
            prompt: .object([:]),
            answer: .object([:])
        )

        XCTAssertEqual(card.promptText, "Study card")
    }

    func testResolvedLegacyClozeDoesNotExposeAnswerOnFront() {
        let card = makeCard(
            cardType: "cloze",
            prompt: .object([
                "clozeDisplayText": .string("私は学生です。"),
            ]),
            answer: .object([:])
        )

        XCTAssertNil(card.presentation.front.heading)
        XCTAssertEqual(card.presentation.back.heading, "私は学生です。")
    }

    func testResolvedImageBackedClozeUsesNeutralLibraryPrompt() {
        let card = makeCard(
            cardType: "cloze",
            prompt: .object([
                "clozeDisplayText": .string("私は学生です。"),
                "cueImage": media(url: "/study/student.png", kind: "image"),
            ]),
            answer: .object([:])
        )

        XCTAssertEqual(card.promptText, "Study card")
        XCTAssertEqual(card.answerText, "私は学生です。")
    }

    func testReviewIntervalLabelsMatchLearningOSIntervals() {
        XCTAssertEqual(ReviewRating.again.nextIntervalLabel, "<10m")
        XCTAssertEqual(ReviewRating.hard.nextIntervalLabel, "1d")
        XCTAssertEqual(ReviewRating.good.nextIntervalLabel, "3d")
        XCTAssertEqual(ReviewRating.easy.nextIntervalLabel, "7d")
    }

    func testResolvedPitchAccentAppearsOnlyOnAnswerFace() {
        let card = makeCard(
            cardType: "recognition",
            prompt: .object(["cueText": .string("会社")]),
            answer: .object([
                "expression": .string("会社"),
                "pitchAccent": .object([
                    "status": .string("resolved"),
                    "expression": .string("会社"),
                    "reading": .string("かいしゃ"),
                    "pitchNum": .number(0),
                    "morae": .array([.string("か"), .string("い"), .string("しゃ")]),
                    "pattern": .array([.number(0), .number(1), .number(1)]),
                    "patternName": .string("平板"),
                    "source": .string("kanjium"),
                    "resolvedBy": .string("local-reading"),
                ]),
            ])
        )

        XCTAssertNil(card.presentation.front.pitchAccent)
        XCTAssertEqual(
            card.presentation.back.pitchAccent,
            .init(
                expression: "会社",
                reading: "かいしゃ",
                morae: ["か", "い", "しゃ"],
                pattern: [0, 1, 1],
                patternName: "平板"
            )
        )
    }

    func testMalformedAndUnresolvedPitchAccentStayHidden() {
        let unresolved = makeCard(
            cardType: "recognition",
            prompt: .object(["cueText": .string("会社")]),
            answer: .object([
                "pitchAccent": .object([
                    "status": .string("unresolved"),
                    "expression": .string("会社"),
                ]),
            ])
        )
        let malformed = makeCard(
            cardType: "recognition",
            prompt: .object(["cueText": .string("会社")]),
            answer: .object([
                "pitchAccent": .object([
                    "status": .string("resolved"),
                    "expression": .string("会社"),
                    "reading": .string("かいしゃ"),
                    "morae": .array([.string("か"), .string("い")]),
                    "pattern": .array([.number(0)]),
                    "patternName": .string("平板"),
                ]),
            ])
        )

        XCTAssertNil(unresolved.presentation.back.pitchAccent)
        XCTAssertNil(malformed.presentation.back.pitchAccent)
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
