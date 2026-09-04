import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testRegenerateAnswerAudioPersistsSettingsAndRefreshesOfflineMedia() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000000AA",
            expression: "会社",
            masteryLevel: "guru"
        )
        try insertEditorCard(card, into: container)

        let regenerated = makeAnswerAudioRegenerationResponse(for: card)
        let responseData = try StorageCodec.encoder.encode(regenerated)
        let paths = LockedRequestPaths()
        let client = makeAnswerAudioRegenerationClient(responseData: responseData, paths: paths)
        let store = makeEditorStore(container: container, client: client)

        let result = try await store.regenerateAnswerAudio(
            for: card,
            voiceID: " fishaudio:875668667eb94c20b09856b971d9ca2f ",
            textOverride: " かいしゃ "
        )

        XCTAssertEqual(
            paths.values,
            [
                "/api/study/cards/\(card.id)/regenerate-answer-audio",
                "/api/study/media/answer-audio",
            ]
        )
        XCTAssertEqual(
            try String(contentsOf: result.localURL, encoding: .utf8),
            "regenerated-audio"
        )
        let stored = try XCTUnwrap(store.libraryCards.first)
        XCTAssertEqual(result.card.masteryLevel, "guru")
        XCTAssertEqual(stored.masteryLevel, "guru")
        XCTAssertEqual(stored.answerAudioSource, "generated")
        XCTAssertEqual(
            stored.answer["answerAudioVoiceId"]?.stringValue,
            "fishaudio:875668667eb94c20b09856b971d9ca2f"
        )
        XCTAssertEqual(stored.answer["answerAudioTextOverride"]?.stringValue, "かいしゃ")
    }

    @MainActor
    func testSavingAfterAudioRegenerationDoesNotRestoreStaleServerAudio() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let baseCard = makeCard(
            id: "01J0000000000000000000000AS",
            expression: "会社"
        )
        let original = makeStaleAudioCard(from: baseCard)
        try insertEditorCard(original, into: container)

        let regenerated = makeFreshAudioCard(from: original)
        let stalePatchResponse = makeStalePatchResponse(from: original, after: regenerated)
        let regeneratedData = try StorageCodec.encoder.encode(regenerated)
        let stalePatchResponseData = try StorageCodec.encoder.encode(stalePatchResponse)
        let client = makeStaleAudioSaveClient(
            regeneratedData: regeneratedData,
            stalePatchData: stalePatchResponseData
        )
        let store = makeEditorStore(container: container, client: client)

        _ = try await store.regenerateAnswerAudio(
            for: original,
            voiceID: "fishaudio:new-voice",
            textOverride: "あたらしい"
        )
        // Simulate dismissing and reopening the editor after regeneration. The
        // protection must outlive the stale view snapshot that initiated it.
        let reopenedCard = try persistedCard(in: container)
        var draft = StudyCardDraft(card: reopenedCard)
        draft.answerAudioVoiceId = "fishaudio:new-voice"
        draft.answerAudioTextOverride = "あたらしい"
        draft.notes = "Saved note"
        try await store.updateCard(reopenedCard, draft: draft)

        let stored = try persistedCard(in: container)
        XCTAssertEqual(stored.prompt["cueAudio"], Self.newPromptAudio)
        XCTAssertEqual(stored.answer["answerAudio"], Self.newAnswerAudio)
        XCTAssertEqual(
            stored.answer["answerAudioVoiceId"],
            .string("fishaudio:new-voice")
        )
        XCTAssertEqual(
            stored.answer["answerAudioTextOverride"],
            .string("あたらしい")
        )
        XCTAssertEqual(stored.answer["notes"]?.stringValue, "Saved note")
    }

    @MainActor
    func testOrdinaryCardSaveAcceptsServerAnswerAudioEnrichment() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let baseCard = makeCard(
            id: "01J0000000000000000000000AE",
            expression: "会社"
        )
        let original = StudyCard(
            id: baseCard.id,
            syncId: baseCard.id,
            noteId: baseCard.noteId,
            cardType: baseCard.cardType,
            prompt: baseCard.prompt,
            answer: baseCard.answer.replacingObjectValues([
                "answerAudio": .object([
                    "url": .string("/api/study/media/answer"),
                ]),
            ]),
            state: baseCard.state,
            answerAudioSource: "generated",
            createdAt: baseCard.createdAt,
            updatedAt: baseCard.updatedAt
        )
        try insertEditorCard(original, into: container)

        let enrichedAudio: JSONValue = .object([
            "url": .string("/api/study/media/answer?signature=rotated"),
            "durationMilliseconds": .number(1_250),
        ])
        let response = StudyCard(
            id: original.id,
            syncId: original.syncId,
            noteId: original.noteId,
            cardType: original.cardType,
            prompt: original.prompt,
            answer: original.answer.replacingObjectValues([
                "answerAudio": enrichedAudio,
                "notes": .string("Saved note"),
            ]),
            state: original.state,
            answerAudioSource: "generated",
            createdAt: original.createdAt,
            updatedAt: original.updatedAt.addingTimeInterval(1)
        )
        let responseData = try StorageCodec.encoder.encode(response)
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                responseData
            )
        }
        let store = makeEditorStore(container: container, client: client)
        var draft = StudyCardDraft(card: original)
        draft.notes = "Saved note"

        try await store.updateCard(original, draft: draft)

        XCTAssertEqual(try persistedCard(in: container).answer["answerAudio"], enrichedAudio)
    }

    @MainActor
    func testOrdinaryCardSavePreservesProgressionLockFromLeanResponse() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let baseCard = makeCard(
            id: "01J0000000000000000000000PL",
            expression: "会社"
        )
        let original = StudyCard(
            id: baseCard.id,
            syncId: baseCard.id,
            noteId: baseCard.noteId,
            cardType: baseCard.cardType,
            prompt: baseCard.prompt,
            answer: baseCard.answer,
            state: baseCard.state,
            answerAudioSource: baseCard.answerAudioSource,
            variantGroupId: "family-1",
            variantStatus: "locked",
            createdAt: baseCard.createdAt,
            updatedAt: baseCard.updatedAt
        )
        try insertEditorCard(original, into: container)

        let response = StudyCard(
            id: original.id,
            syncId: original.syncId,
            noteId: original.noteId,
            cardType: original.cardType,
            prompt: original.prompt,
            answer: original.answer.replacingObjectValues([
                "notes": .string("Saved note"),
            ]),
            state: original.state,
            answerAudioSource: original.answerAudioSource,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt.addingTimeInterval(1)
        )
        var responseObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: StorageCodec.encoder.encode(response)
            ) as? [String: Any]
        )
        responseObject.removeValue(forKey: "variantGroupId")
        responseObject.removeValue(forKey: "variantStatus")
        let responseData = try JSONSerialization.data(withJSONObject: responseObject)
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                responseData
            )
        }
        let store = makeEditorStore(container: container, client: client)
        var draft = StudyCardDraft(card: original)
        draft.notes = "Saved note"

        try await store.updateCard(original, draft: draft)

        let persisted = try persistedCard(in: container)
        XCTAssertEqual(persisted.answer["notes"]?.stringValue, "Saved note")
        XCTAssertEqual(persisted.variantGroupId, "family-1")
        XCTAssertEqual(persisted.variantStatus, "locked")
    }

    @MainActor
    private func makeAnswerAudioRegenerationResponse(for card: StudyCard) -> StudyCard {
        StudyCard(
            id: card.id,
            syncId: card.id,
            noteId: nil,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer.replacingObjectValues([
                "answerAudioVoiceId": .string("fishaudio:875668667eb94c20b09856b971d9ca2f"),
                "answerAudioTextOverride": .string("かいしゃ"),
                "answerAudio": .object([
                    "url": .string("/api/study/media/answer-audio"),
                    "filename": .string("answer.mp3"),
                ]),
            ]),
            state: card.state,
            answerAudioSource: "generated",
            createdAt: card.createdAt,
            updatedAt: card.updatedAt.addingTimeInterval(1)
        )
    }

    @MainActor
    private func makeAnswerAudioRegenerationClient(
        responseData: Data,
        paths: LockedRequestPaths
    ) -> APIClient {
        makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            guard path.hasSuffix("/regenerate-answer-audio") else {
                return Self.audioResponse(for: request, data: Data("regenerated-audio".utf8))
            }
            XCTAssertEqual(request.timeoutInterval, 180)
            let payload = try JSONSerialization.jsonObject(
                with: requestBody(request)
            ) as? [String: Any]
            XCTAssertEqual(
                payload?["answerAudioVoiceId"] as? String,
                "fishaudio:875668667eb94c20b09856b971d9ca2f"
            )
            XCTAssertEqual(payload?["answerAudioTextOverride"] as? String, "かいしゃ")
            return Self.response(statusCode: 200, data: responseData)
        }
    }

    @MainActor
    private func makeStaleAudioSaveClient(
        regeneratedData: Data,
        stalePatchData: Data
    ) -> APIClient {
        makeClient { request in
            if request.url?.path.hasSuffix("/regenerate-answer-audio") == true {
                return Self.response(statusCode: 200, data: regeneratedData)
            }
            guard request.httpMethod == "PATCH" else {
                return Self.audioResponse(for: request, data: Data("new-audio".utf8))
            }
            let payload = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            )
            let answer = try XCTUnwrap(payload["answer"] as? [String: Any])
            let audio = try XCTUnwrap(answer["answerAudio"] as? [String: Any])
            XCTAssertEqual(audio["url"] as? String, "/api/study/media/new-answer")
            let prompt = try XCTUnwrap(payload["prompt"] as? [String: Any])
            let promptAudio = try XCTUnwrap(prompt["cueAudio"] as? [String: Any])
            XCTAssertEqual(promptAudio["url"] as? String, "/api/study/media/new-prompt")
            return Self.response(statusCode: 200, data: stalePatchData)
        }
    }

    @MainActor
    private func makeStaleAudioCard(from card: StudyCard) -> StudyCard {
        StudyCard(
            id: card.id,
            syncId: card.id,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt.replacingObjectValues([
                "cueText": .null,
                "cueMeaning": .null,
                "cueAudio": .object(["url": .string("/api/study/media/old-prompt")]),
            ]),
            answer: card.answer.replacingObjectValues([
                "answerAudio": .object(["url": .string("/api/study/media/old-answer")]),
                "answerAudioVoiceId": .string("fishaudio:old-voice"),
                "answerAudioTextOverride": .string("ふるい"),
            ]),
            state: card.state,
            answerAudioSource: "generated",
            createdAt: card.createdAt,
            updatedAt: card.updatedAt
        )
    }

    @MainActor
    private func makeFreshAudioCard(from card: StudyCard) -> StudyCard {
        StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt.replacingObjectValues(["cueAudio": Self.newPromptAudio]),
            answer: card.answer.replacingObjectValues([
                "answerAudio": Self.newAnswerAudio,
                "answerAudioVoiceId": .string("fishaudio:new-voice"),
                "answerAudioTextOverride": .string("あたらしい"),
            ]),
            state: card.state,
            answerAudioSource: "generated",
            createdAt: card.createdAt,
            updatedAt: card.updatedAt.addingTimeInterval(1)
        )
    }

    @MainActor
    private func makeStalePatchResponse(from card: StudyCard, after regenerated: StudyCard) -> StudyCard {
        StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer.replacingObjectValues(["notes": .string("Saved note")]),
            state: card.state,
            answerAudioSource: "generated",
            createdAt: card.createdAt,
            updatedAt: regenerated.updatedAt.addingTimeInterval(1)
        )
    }

    private static let newAnswerAudio: JSONValue = .object([
        "url": .string("/api/study/media/new-answer"),
    ])
    private static let newPromptAudio: JSONValue = .object([
        "url": .string("/api/study/media/new-prompt"),
    ])

    private static func audioResponse(
        for request: URLRequest,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!,
            data
        )
    }
}
