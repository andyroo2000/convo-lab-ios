import XCTest
@testable import ConvoLab

@MainActor
final class StudyCardPresentationTests: XCTestCase {
    func testServerPresentationV1OverridesDivergentRawReviewFieldsAndPersists() throws {
        let card = try decodedCard(presentation: #"""
        {
          "version":1,
          "front":{
            "mode":"text","text":"SERVER FRONT","ruby":"会社[かいしゃ]",
            "hint":"SERVER HINT",
            "media":{"audio":null,"image":{"url":"/media/server-front.png"}},
            "autoplayAudio":false
          },
          "answer":{
            "heading":"SERVER HEADING","ruby":"答[こた]え",
            "restored":"SERVER RESTORED","meaning":"SERVER MEANING",
            "sentences":{
              "japanese":{"text":"日本語の文","ruby":"日本語[にほんご]の文[ぶん]"},
              "english":{"text":"Server sentence","ruby":null}
            },
            "notes":["Server note"],
            "media":{"image":{"url":"/media/server-answer.png"}},
            "audio":null,
            "pitchAccent":{
              "status":"resolved","expression":"答え","reading":"こたえ",
              "morae":["こ","た","え"],"pattern":[0,1,1],"patternName":"平板"
            }
          }
        }
        """#)

        XCTAssertEqual(card.serverPresentation?.version, 1)
        XCTAssertEqual(card.presentation.front.heading, "会社[かいしゃ]")
        XCTAssertEqual(card.presentation.front.supportingText, "SERVER HINT")
        XCTAssertNil(card.presentation.front.audioURL)
        XCTAssertEqual(
            card.presentation.front.imageURL,
            URL(string: "/media/server-front.png")
        )
        XCTAssertFalse(card.shouldAutoplayPromptAudio)
        XCTAssertEqual(card.presentation.back.heading, "答[こた]え")
        XCTAssertEqual(
            card.presentation.back.textBlocks.map(\.role),
            [.restoredText, .meaning, .sentenceJapanese, .sentenceEnglish, .note]
        )
        XCTAssertEqual(
            card.presentation.back.textBlocks.map(\.text),
            [
                "SERVER RESTORED",
                "SERVER MEANING",
                "日本語[にほんご]の文[ぶん]",
                "Server sentence",
                "Server note",
            ]
        )
        XCTAssertNil(card.presentation.back.audioURL)
        XCTAssertEqual(card.promptText, "会社")
        XCTAssertEqual(card.answerText, "SERVER MEANING")
        XCTAssertEqual(card.presentation.back.pitchAccent?.reading, "こたえ")

        let persisted = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: StorageCodec.encoder.encode(card)
        )
        XCTAssertEqual(persisted.serverPresentation, card.serverPresentation)
        XCTAssertEqual(persisted.presentation, card.presentation)
    }

    func testMissingAndFuturePresentationVersionsUseRawCompatibilityProjection() throws {
        let missing = try decodedCard(presentation: nil)
        let future = try decodedCard(presentation: #"{"version":2,"futureShape":true}"#)

        for card in [missing, future] {
            XCTAssertNil(card.serverPresentation)
            XCTAssertEqual(card.presentation.front.heading, "RAW FRONT")
            XCTAssertEqual(card.presentation.back.textBlocks.map(\.text), ["RAW MEANING"])
            XCTAssertEqual(
                card.presentation.back.audioURL,
                URL(string: "/media/raw-prompt.mp3")
            )
        }
    }

    func testKnownPresentationV1RejectsMalformedTypedMediaAndPitchAccent() {
        let unresolvedPitch = #"""
        {
          "status":"unresolved","expression":"答え","reading":"こたえ",
          "morae":["こ","た","え"],"pattern":[0,1,1],"patternName":"平板"
        }
        """#
        let mismatchedPitch = #"""
        {
          "status":"resolved","expression":"答え","reading":"こたえ",
          "morae":["こ","た","え"],"pattern":[0,1],"patternName":"平板"
        }
        """#
        let malformedPresentations = [
            minimalPresentation(frontAudio: #""not-an-object""#, pitchAccent: "null"),
            minimalPresentation(frontAudio: #"{"id":null}"#, pitchAccent: "null"),
            minimalPresentation(frontAudio: "null", pitchAccent: unresolvedPitch),
            minimalPresentation(frontAudio: "null", pitchAccent: mismatchedPitch),
        ]

        for presentation in malformedPresentations {
            XCTAssertThrowsError(try decodedCard(presentation: presentation))
        }
    }

    func testOptimisticSchedulingPreservesProjectionWhileContentEditsInvalidateIt() throws {
        let card = try decodedCard(presentation: #"""
        {
          "version":1,
          "front":{
            "mode":"text","text":"SERVER FRONT","ruby":null,"hint":null,
            "media":{"audio":null,"image":null},"autoplayAudio":false
          },
          "answer":{
            "heading":"SERVER ANSWER","ruby":null,"restored":null,"meaning":null,
            "sentences":{
              "japanese":{"text":null,"ruby":null},
              "english":{"text":null,"ruby":null}
            },
            "notes":[],"media":{"image":null},"audio":null,"pitchAccent":null
          }
        }
        """#)
        let scheduled = try StudyCardActionProjection.prepare(
            action: .suspend,
            card: card,
            mode: nil,
            dueAt: nil,
            timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ).card

        XCTAssertEqual(scheduled.serverPresentation, card.serverPresentation)
        XCTAssertEqual(scheduled.presentation.front.heading, "SERVER FRONT")

        var draft = StudyCardDraft(card: card)
        draft.cueText = "LOCAL EDIT"
        let edited = StudyCardEditorProjection.updating(
            card,
            with: draft,
            at: Date(timeIntervalSince1970: 1_800_000_100)
        ).card

        XCTAssertNil(edited.serverPresentation)
        XCTAssertEqual(edited.presentation.front.heading, "LOCAL EDIT")
    }

    func testPromptAutoplayMatchesDesktopAudioRecognitionRules() {
        let audio = media(url: "https://example.com/prompt.mp3", kind: "audio")
        let audioRecognition = makeCard(
            cardType: "recognition",
            prompt: .object(["cueAudio": audio]),
            answer: .object([:])
        )
        let labeledRecognition = makeCard(
            cardType: "recognition",
            prompt: .object([
                "cueAudio": audio,
                "cueMeaning": .string("名詞"),
            ]),
            answer: .object([:])
        )
        let audioProduction = makeCard(
            cardType: "production",
            prompt: .object(["cueAudio": audio]),
            answer: .object([:])
        )

        XCTAssertTrue(audioRecognition.shouldAutoplayPromptAudio)
        XCTAssertFalse(labeledRecognition.shouldAutoplayPromptAudio)
        XCTAssertFalse(audioProduction.shouldAutoplayPromptAudio)
    }

    func testPromptOnlyAudioIsReusedOnTheAnswerSide() {
        let audio = media(url: "https://example.com/listening-example.mp3", kind: "audio")
        let card = makeCard(
            cardType: "recognition",
            prompt: .object(["cueAudio": audio]),
            answer: .object([:])
        )

        XCTAssertEqual(card.audioURL, URL(string: "https://example.com/listening-example.mp3"))
        XCTAssertEqual(card.presentation.front.audioURL, card.audioURL)
        XCTAssertEqual(card.presentation.back.audioURL, card.audioURL)
    }

    func testLegacyAnswerOnlyAudioRemainsAvailable() {
        let audio = media(url: "https://example.com/legacy-answer.mp3", kind: "audio")
        let card = makeCard(
            cardType: "recognition",
            prompt: .object(["cueText": .string("会社")]),
            answer: .object(["answerAudio": audio])
        )

        XCTAssertNil(card.presentation.front.audioURL)
        XCTAssertEqual(card.presentation.back.audioURL, card.audioURL)
    }

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

    func testReviewIntervalLabelsMatchDesktopFormatting() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(
            FSRSReviewScheduler.intervalLabel(
                dueAt: now.addingTimeInterval(10 * 60),
                reviewedAt: now
            ),
            "<10m"
        )
        XCTAssertEqual(
            FSRSReviewScheduler.intervalLabel(
                dueAt: now.addingTimeInterval(104 * 24 * 60 * 60),
                reviewedAt: now
            ),
            "104d"
        )
        XCTAssertEqual(
            FSRSReviewScheduler.intervalLabel(
                dueAt: now.addingTimeInterval(400 * 24 * 60 * 60),
                reviewedAt: now
            ),
            "1y"
        )
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

    private func decodedCard(presentation: String?) throws -> StudyCard {
        let presentationField = presentation.map { ",\"presentation\":\($0)" } ?? ""
        return try StorageCodec.decoder.decode(
            StudyCard.self,
            from: Data(#"""
            {
              "id":"01J60000000000000000000001","syncId":null,"noteId":null,
              "revision":3,"cardType":"recognition",
              "prompt":{
                "cueText":"RAW FRONT","cueMeaning":"RAW HINT",
                "cueAudio":{"url":"/media/raw-prompt.mp3"}
              },
              "answer":{
                "expression":"RAW ANSWER","meaning":"RAW MEANING",
                "answerAudio":{"url":"/media/raw-answer.mp3"}
              }
              \#(presentationField),
              "state":{
                "dueAt":null,"introducedAt":null,"failedAt":null,
                "queueState":"review","scheduler":null,"source":{}
              },
              "answerAudioSource":"imported",
              "createdAt":"2026-08-20T10:11:12.000Z",
              "updatedAt":"2026-08-20T10:11:13.000Z"
            }
            """#.utf8)
        )
    }

    private func minimalPresentation(frontAudio: String, pitchAccent: String) -> String {
        #"""
        {
          "version":1,
          "front":{
            "mode":"text","text":"front","ruby":null,"hint":null,
            "media":{"audio":\#(frontAudio),"image":null},"autoplayAudio":false
          },
          "answer":{
            "heading":"answer","ruby":null,"restored":null,"meaning":null,
            "sentences":{
              "japanese":{"text":null,"ruby":null},
              "english":{"text":null,"ruby":null}
            },
            "notes":[],"media":{"image":null},"audio":null,
            "pitchAccent":\#(pitchAccent)
          }
        }
        """#
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
