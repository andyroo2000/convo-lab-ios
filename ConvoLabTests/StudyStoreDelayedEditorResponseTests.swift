import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testSlowImageRegenerationPreservesNewerSyncedCardText() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000000IR",
            expression: "会社"
        )
        let record = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        container.mainContext.insert(record)
        try container.mainContext.save()

        let generatedImage: JSONValue = .object([
            "url": .string("/api/study/media/race-image"),
            "filename": .string("race.webp"),
        ])
        let regenerated = makeGeneratedImageCard(from: card, image: generatedImage)
        let responseData = try StorageCodec.encoder.encode(regenerated)
        let gate = LockedRequestGate()
        let client = makeDelayedImageEditorClient(responseData: responseData, gate: gate)
        let store = makeEditorStore(container: container, client: client)
        let regeneration = Task {
            try await store.regenerateImage(
                for: card,
                prompt: "A company office.",
                placement: .answer
            )
        }
        await waitUntil { gate.hasStarted }
        let concurrentlySyncedPromptImage: JSONValue = .object([
            "url": .string("/api/study/media/newer-front"),
            "filename": .string("newer-front.webp"),
        ])
        let newerCard = StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt.replacingObjectValues([
                "cueText": .string("新しい会社"),
                "cueImage": concurrentlySyncedPromptImage,
            ]),
            answer: card.answer.replacingObjectValues([
                "meaning": .string("newer company"),
            ]),
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: card.updatedAt.addingTimeInterval(2)
        )
        record.payload = try StorageCodec.encoder.encode(newerCard)
        record.serverUpdatedAt = newerCard.updatedAt
        record.locallyUpdatedAt = nil
        try container.mainContext.save()
        gate.release()

        let result = try await regeneration.value
        XCTAssertEqual(result.card.prompt["cueText"], .string("新しい会社"))
        XCTAssertEqual(result.card.prompt["cueImage"], concurrentlySyncedPromptImage)
        XCTAssertEqual(result.card.answer["meaning"], .string("newer company"))
        XCTAssertEqual(result.card.answer["answerImage"], generatedImage)
        XCTAssertEqual(try persistedCard(in: container), result.card)
    }

    @MainActor
    func testCancelledRegenerationStillReconcilesCompletedServerAndCacheChanges() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000000AB",
            expression: "会社"
        )
        try insertEditorCard(card, into: container)

        let regenerated = makeGeneratedAnswerAudioCard(
            from: card,
            url: "/api/study/media/cancelled-answer",
            includeSettings: true
        )
        let gate = LockedRequestGate()
        let client = makeDelayedAnswerAudioDownloadClient(
            responseData: try StorageCodec.encoder.encode(regenerated),
            gate: gate
        )
        let store = makeEditorStore(container: container, client: client)

        let regeneration = Task {
            try await store.regenerateAnswerAudio(
                for: card,
                voiceID: "fishaudio:new-voice",
                textOverride: "かいしゃ"
            )
        }
        await waitUntil { gate.hasStarted }
        regeneration.cancel()
        gate.release()
        let result = try await regeneration.value

        XCTAssertEqual(
            try String(contentsOf: result.localURL, encoding: .utf8),
            "regenerated-audio"
        )
        let stored = try persistedCard(in: container)
        XCTAssertEqual(stored.answerAudioSource, "generated")
        XCTAssertEqual(
            stored.answer["answerAudioVoiceId"]?.stringValue,
            "fishaudio:new-voice"
        )
        XCTAssertEqual(
            stored.answer["answerAudioTextOverride"]?.stringValue,
            "かいしゃ"
        )
        XCTAssertEqual(store.libraryCards.first, stored)
    }

    @MainActor
    func testSlowAnswerAudioResponsePreservesNewerSyncedCardText() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000000AC",
            expression: "会社"
        )
        let record = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        container.mainContext.insert(record)
        try container.mainContext.save()

        let regenerated = makeGeneratedAnswerAudioCard(
            from: card,
            url: "/api/study/media/race-answer"
        )
        let gate = LockedRequestGate()
        let client = makeDelayedAnswerAudioClient(
            responseData: try StorageCodec.encoder.encode(regenerated),
            gate: gate
        )
        let store = makeEditorStore(container: container, client: client)

        let regeneration = Task {
            try await store.regenerateAnswerAudio(
                for: card,
                voiceID: StudyAnswerVoice.defaultVoice.id,
                textOverride: ""
            )
        }
        await waitUntil { gate.hasStarted }
        let newerCard = StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt.replacingObjectValues([
                "cueText": .string("新しい会社"),
            ]),
            answer: card.answer.replacingObjectValues([
                "meaning": .string("newer company"),
            ]),
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: card.updatedAt.addingTimeInterval(2)
        )
        record.payload = try StorageCodec.encoder.encode(newerCard)
        record.serverUpdatedAt = newerCard.updatedAt
        record.locallyUpdatedAt = nil
        try container.mainContext.save()
        gate.release()

        let result = try await regeneration.value

        XCTAssertEqual(result.card.prompt["cueText"]?.stringValue, "新しい会社")
        XCTAssertEqual(result.card.answer["meaning"]?.stringValue, "newer company")
        XCTAssertEqual(
            result.card.answer["answerAudio"]?["url"]?.stringValue,
            "/api/study/media/race-answer"
        )
        XCTAssertEqual(store.libraryCards.first, result.card)
    }

    @MainActor
    func testRegenerateAnswerAudioDoesNotTreatQuarantinedEditAsPending() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000000AB",
            expression: "教材"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        let update = PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: card.id,
            payload: try StorageCodec.encoder.encode(
                UpdateStudyCardRequest(prompt: card.prompt, answer: card.answer)
            )
        )
        update.lastError = "HTTP 422: Rejected"
        container.mainContext.insert(update)
        try container.mainContext.save()
        let requestCounter = LockedCounter()
        let client = makeClient { _ in
            _ = requestCounter.next()
            throw URLError(.badServerResponse)
        }
        let store = makeEditorStore(container: container, client: client)

        do {
            _ = try await store.regenerateAnswerAudio(
                for: card,
                voiceID: StudyAnswerVoice.defaultVoice.id,
                textOverride: ""
            )
            XCTFail("Expected the attempted network request to fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badServerResponse)
        }

        XCTAssertEqual(requestCounter.current, 1)
        let stored = try XCTUnwrap(store.libraryCards.first)
        XCTAssertEqual(stored.id, card.id)
        XCTAssertEqual(stored.prompt, card.prompt)
        XCTAssertEqual(stored.answer, card.answer)
        XCTAssertEqual(stored.state, card.state)
    }

    @MainActor
    func testUnrelatedRejectedCardEditDoesNotBlockAnswerAudioRegeneration() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let target = makeCard(
            id: "01J0000000000000000000000AD",
            expression: "健康"
        )
        let rejected = makeCard(
            id: "01J0000000000000000000000AE",
            expression: "拒否"
        )
        for (index, card) in [target, rejected].enumerated() {
            container.mainContext.insert(
                LocalCardRecord(
                    card: card,
                    userID: 1,
                    queueIndex: index,
                    payload: try StorageCodec.encoder.encode(card)
                )
            )
        }
        container.mainContext.insert(
            PendingMutation(
                kind: "cardUpdate",
                userID: 1,
                resourceID: rejected.id,
                payload: try StorageCodec.encoder.encode(
                    UpdateStudyCardRequest(
                        prompt: rejected.prompt,
                        answer: rejected.answer
                    )
                )
            )
        )
        try container.mainContext.save()

        let regenerated = makeGeneratedAnswerAudioCard(
            from: target,
            url: "/api/study/media/healthy-answer"
        )
        let regeneratedData = try StorageCodec.encoder.encode(regenerated)
        let paths = LockedRequestPaths()
        let targetID = target.id
        let rejectedID = rejected.id
        let client = makeRejectedEditAudioClient(
            rejectedID: rejectedID,
            regeneratedData: regeneratedData,
            paths: paths
        )
        let store = makeEditorStore(container: container, client: client)

        let result = try await store.regenerateAnswerAudio(
            for: target,
            voiceID: StudyAnswerVoice.defaultVoice.id,
            textOverride: ""
        )

        XCTAssertEqual(
            paths.values,
            [
                "/api/study/cards/\(rejected.id)",
                "/api/study/cards/\(targetID)/regenerate-answer-audio",
                "/api/study/media/healthy-answer",
            ]
        )
        XCTAssertEqual(result.card.answerAudioSource, "generated")
        let rejectedMutation = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>()).first
        )
        XCTAssertEqual(rejectedMutation.resourceID, rejected.id)
        XCTAssertNotNil(rejectedMutation.lastError)
    }

    @MainActor
    private func makeGeneratedImageCard(from card: StudyCard, image: JSONValue) -> StudyCard {
        StudyCard(
            id: card.id,
            syncId: card.id,
            noteId: nil,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer.replacingObjectValues(["answerImage": image]),
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: card.updatedAt.addingTimeInterval(1)
        )
    }

    @MainActor
    private func makeGeneratedAnswerAudioCard(
        from card: StudyCard,
        url: String,
        includeSettings: Bool = false
    ) -> StudyCard {
        var answerChanges: [String: JSONValue] = [
            "answerAudio": .object(["url": .string(url)]),
        ]
        if includeSettings {
            answerChanges["answerAudioVoiceId"] = .string("fishaudio:new-voice")
            answerChanges["answerAudioTextOverride"] = .string("かいしゃ")
        }
        return StudyCard(
            id: card.id,
            syncId: card.id,
            noteId: nil,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer.replacingObjectValues(answerChanges),
            state: card.state,
            answerAudioSource: "generated",
            createdAt: card.createdAt,
            updatedAt: card.updatedAt.addingTimeInterval(1)
        )
    }

    @MainActor
    private func makeDelayedImageEditorClient(
        responseData: Data,
        gate: LockedRequestGate
    ) -> APIClient {
        makeClient { request in
            guard request.url?.path.hasSuffix("/regenerate-image") == true else {
                return Self.mediaResponse(
                    for: request,
                    contentType: "image/webp",
                    data: Data("race-image".utf8)
                )
            }
            let payload = try JSONSerialization.jsonObject(
                with: requestBody(request)
            ) as? [String: Any]
            XCTAssertEqual(payload?["imageRole"] as? String, "answer")
            gate.markStarted()
            gate.waitForRelease()
            return Self.response(data: responseData)
        }
    }

    @MainActor
    private func makeRejectedEditAudioClient(
        rejectedID: String,
        regeneratedData: Data,
        paths: LockedRequestPaths
    ) -> APIClient {
        makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path == "/api/study/cards/\(rejectedID)" {
                return Self.response(
                    statusCode: 422,
                    data: Data(#"{"message":"Rejected edit"}"#.utf8)
                )
            }
            if path.hasSuffix("/regenerate-answer-audio") {
                return Self.response(data: regeneratedData)
            }
            return Self.mediaResponse(
                for: request,
                contentType: "audio/mpeg",
                data: Data("healthy-audio".utf8)
            )
        }
    }

    private static func mediaResponse(
        for request: URLRequest,
        contentType: String,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": contentType]
            )!,
            data
        )
    }
}
