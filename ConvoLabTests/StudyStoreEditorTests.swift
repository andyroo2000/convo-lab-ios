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
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()

        let regenerated = StudyCard(
            id: card.id,
            syncId: card.id,
            noteId: nil,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer.replacingObjectValues([
                "answerAudioVoiceId": .string(
                    "fishaudio:875668667eb94c20b09856b971d9ca2f"
                ),
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
        let responseData = try StorageCodec.encoder.encode(regenerated)
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.hasSuffix("/regenerate-answer-audio") {
                XCTAssertEqual(request.timeoutInterval, 180)
                let body = try requestBody(request)
                let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                XCTAssertEqual(
                    payload?["answerAudioVoiceId"] as? String,
                    "fishaudio:875668667eb94c20b09856b971d9ca2f"
                )
                XCTAssertEqual(payload?["answerAudioTextOverride"] as? String, "かいしゃ")
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
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("regenerated-audio".utf8)
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

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
    func testRegenerateImagePersistsPlacementAndDownloadsForOfflineUse() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000000IM",
            expression: "会社"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()

        let generatedImage: JSONValue = .object([
            "id": .string("01J00000000000000000000IMG"),
            "filename": .string("company.webp"),
            "url": .string("/api/study/media/company-image?signature=front"),
            "mediaKind": .string("image"),
            "source": .string("generated"),
        ])
        let signedAnswerImage: JSONValue = .object([
            "id": .string("01J00000000000000000000IMG"),
            "filename": .string("company.webp"),
            "url": .string("/api/study/media/company-image?signature=back"),
            "mediaKind": .string("image"),
            "source": .string("generated"),
        ])
        let regenerated = StudyCard(
            id: card.id,
            syncId: card.id,
            noteId: nil,
            cardType: card.cardType,
            prompt: card.prompt.replacingObjectValues([
                "cueImage": generatedImage,
            ]),
            answer: card.answer.replacingObjectValues([
                "answerImage": signedAnswerImage,
            ]),
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: card.updatedAt.addingTimeInterval(1)
        )
        let responseData = try StorageCodec.encoder.encode(regenerated)
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.hasSuffix("/regenerate-image") {
                XCTAssertEqual(request.timeoutInterval, 180)
                let body = try requestBody(request)
                let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                XCTAssertEqual(payload?["imagePrompt"] as? String, "A Tokyo office.")
                XCTAssertEqual(payload?["imageRole"] as? String, "both")
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
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/webp"]
                )!,
                Data("generated-image".utf8)
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        let result = try await store.regenerateImage(
            for: card,
            prompt: "  A Tokyo office.  ",
            placement: .both
        )

        XCTAssertEqual(
            paths.values,
            [
                "/api/study/cards/\(card.id)/regenerate-image",
                "/api/study/media/company-image",
            ]
        )
        XCTAssertEqual(
            try String(contentsOf: result.localURL, encoding: .utf8),
            "generated-image"
        )
        XCTAssertEqual(result.card.prompt["cueImage"], generatedImage)
        XCTAssertEqual(result.card.answer["answerImage"], generatedImage)
        let stored = try persistedCard(in: container)
        XCTAssertEqual(stored.prompt["cueImage"], generatedImage)
        XCTAssertEqual(stored.answer["answerImage"], generatedImage)
    }

    @MainActor
    func testBothImageRegenerationRejectsDistinctServerImages() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000000IW",
            expression: "会社"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let frontImage: JSONValue = .object([
            "url": .string("/api/study/media/generated-front"),
        ])
        let backImage: JSONValue = .object([
            "url": .string("/api/study/media/generated-back"),
        ])
        let serverCard = StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt.replacingObjectValues(["cueImage": frontImage]),
            answer: card.answer.replacingObjectValues(["answerImage": backImage]),
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: card.updatedAt.addingTimeInterval(1)
        )
        let responseData = try StorageCodec.encoder.encode(serverCard)
        let requestCount = LockedCounter()
        let client = makeClient { request in
            _ = requestCount.next()
            XCTAssertTrue(request.url?.path.hasSuffix("/regenerate-image") == true)
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
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        do {
            _ = try await store.regenerateImage(
                for: card,
                prompt: "A company office.",
                placement: .both
            )
            XCTFail("Expected distinct images for a shared-image request to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "The server returned different front and back images for a shared-image request."
            )
        }

        XCTAssertEqual(requestCount.current, 1)
        let persisted = try persistedCard(in: container)
        XCTAssertEqual(persisted.prompt, card.prompt)
        XCTAssertEqual(persisted.answer, card.answer)
        XCTAssertEqual(persisted.state, card.state)
    }

    @MainActor
    func testRegenerateImageExplicitlyConvertsIndependentImagesToSelectedPlacement() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let frontImage: JSONValue = .object([
            "url": .string("/api/study/media/original-front"),
            "filename": .string("front.webp"),
        ])
        let backImage: JSONValue = .object([
            "url": .string("/api/study/media/original-back"),
            "filename": .string("back.webp"),
        ])
        let baseCard = makeCard(
            id: "01J0000000000000000000000ID",
            expression: "会社"
        )
        let card = StudyCard(
            id: baseCard.id,
            syncId: baseCard.syncId,
            noteId: baseCard.noteId,
            cardType: baseCard.cardType,
            prompt: baseCard.prompt.replacingObjectValues(["cueImage": frontImage]),
            answer: baseCard.answer.replacingObjectValues(["answerImage": backImage]),
            state: baseCard.state,
            answerAudioSource: baseCard.answerAudioSource,
            createdAt: baseCard.createdAt,
            updatedAt: baseCard.updatedAt
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()

        let generatedImage: JSONValue = .object([
            "url": .string("/api/study/media/replacement"),
            "filename": .string("replacement.webp"),
        ])
        let serverCard = StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer.replacingObjectValues(["answerImage": generatedImage]),
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: card.updatedAt.addingTimeInterval(1)
        )
        let responseData = try StorageCodec.encoder.encode(serverCard)
        let client = makeClient { request in
            if request.url?.path.hasSuffix("/regenerate-image") == true {
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
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/webp"]
                )!,
                Data("replacement-image".utf8)
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        let result = try await store.regenerateImage(
            for: card,
            prompt: "A company office.",
            placement: .answer
        )

        XCTAssertEqual(result.card.prompt["cueImage"], .null)
        XCTAssertEqual(result.card.answer["answerImage"], generatedImage)
        let stored = try persistedCard(in: container)
        XCTAssertEqual(stored.prompt["cueImage"], .null)
        XCTAssertEqual(stored.answer["answerImage"], generatedImage)
    }

    @MainActor
    func testCancelledImageRegenerationStillReconcilesCompletedChanges() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000000IC",
            expression: "会社"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let generatedImage: JSONValue = .object([
            "url": .string("/api/study/media/cancelled-image"),
            "filename": .string("cancelled.webp"),
        ])
        let regenerated = StudyCard(
            id: card.id,
            syncId: card.id,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer.replacingObjectValues(["answerImage": generatedImage]),
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: card.updatedAt.addingTimeInterval(1)
        )
        let responseData = try StorageCodec.encoder.encode(regenerated)
        let gate = LockedRequestGate()
        let client = makeClient { request in
            if request.url?.path.hasSuffix("/regenerate-image") == true {
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
            gate.markStarted()
            gate.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/webp"]
                )!,
                Data("cancelled-image".utf8)
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        let regeneration = Task {
            try await store.regenerateImage(
                for: card,
                prompt: "A company office.",
                placement: .answer
            )
        }
        await waitUntil { gate.hasStarted }
        regeneration.cancel()
        gate.release()
        let result = try await regeneration.value

        XCTAssertEqual(result.card.answer["answerImage"], generatedImage)
        XCTAssertEqual(try persistedCard(in: container), result.card)
        XCTAssertEqual(
            try String(contentsOf: result.localURL, encoding: .utf8),
            "cancelled-image"
        )
    }

    @MainActor
    func testImageRegenerationValidatesInputAndBlocksPendingCardWrite() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000000IV",
            expression: "会社"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        let pendingUpdate = PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: card.id,
            payload: try StorageCodec.encoder.encode(
                UpdateStudyCardRequest(prompt: card.prompt, answer: card.answer)
            )
        )
        pendingUpdate.lastError = "HTTP 422: Rejected"
        container.mainContext.insert(pendingUpdate)
        try container.mainContext.save()
        let requestCounter = LockedCounter()
        let client = makeClient { _ in
            _ = requestCounter.next()
            throw URLError(.badServerResponse)
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        do {
            _ = try await store.regenerateImage(
                for: card,
                prompt: "   ",
                placement: .answer
            )
            XCTFail("Expected an empty image prompt to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Enter a non-empty image prompt no longer than 1,000 characters."
            )
        }
        do {
            _ = try await store.regenerateImage(
                for: card,
                prompt: "A company office.",
                placement: .none
            )
            XCTFail("Expected no-image placement to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Choose Front, Back, or Front and back before regenerating an image."
            )
        }
        do {
            _ = try await store.regenerateImage(
                for: card,
                prompt: "A company office.",
                placement: .answer
            )
            XCTFail("Expected an unresolved card edit to block regeneration")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Sync this card’s pending changes before regenerating its image."
            )
        }
        XCTAssertEqual(requestCounter.current, 0)
    }

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
        let regenerated = StudyCard(
            id: card.id,
            syncId: card.id,
            noteId: nil,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer.replacingObjectValues([
                "answerImage": generatedImage,
            ]),
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: card.updatedAt.addingTimeInterval(1)
        )
        let responseData = try StorageCodec.encoder.encode(regenerated)
        let gate = LockedRequestGate()
        let client = makeClient { request in
            if request.url?.path.hasSuffix("/regenerate-image") == true {
                let body = try requestBody(request)
                let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                XCTAssertEqual(payload?["imageRole"] as? String, "answer")
                gate.markStarted()
                gate.waitForRelease()
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
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/webp"]
                )!,
                Data("race-image".utf8)
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
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
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()

        let regenerated = StudyCard(
            id: card.id,
            syncId: card.id,
            noteId: nil,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer.replacingObjectValues([
                "answerAudioVoiceId": .string("fishaudio:new-voice"),
                "answerAudioTextOverride": .string("かいしゃ"),
                "answerAudio": .object([
                    "url": .string("/api/study/media/cancelled-answer"),
                ]),
            ]),
            state: card.state,
            answerAudioSource: "generated",
            createdAt: card.createdAt,
            updatedAt: card.updatedAt.addingTimeInterval(1)
        )
        let gate = LockedRequestGate()
        let client = makeDelayedAnswerAudioDownloadClient(
            responseData: try StorageCodec.encoder.encode(regenerated),
            gate: gate
        )
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

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

        let regenerated = StudyCard(
            id: card.id,
            syncId: card.id,
            noteId: nil,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer.replacingObjectValues([
                "answerAudio": .object([
                    "url": .string("/api/study/media/race-answer"),
                ]),
            ]),
            state: card.state,
            answerAudioSource: "generated",
            createdAt: card.createdAt,
            updatedAt: card.updatedAt.addingTimeInterval(1)
        )
        let gate = LockedRequestGate()
        let client = makeDelayedAnswerAudioClient(
            responseData: try StorageCodec.encoder.encode(regenerated),
            gate: gate
        )
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

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
    func testRegenerateAnswerAudioDoesNotOverwriteQuarantinedLocalEdit() async throws {
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
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        do {
            _ = try await store.regenerateAnswerAudio(
                for: card,
                voiceID: StudyAnswerVoice.defaultVoice.id,
                textOverride: ""
            )
            XCTFail("Expected unresolved local edit to block regeneration")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Sync this card’s pending changes before regenerating its audio."
            )
        }

        XCTAssertEqual(requestCounter.current, 0)
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

        let regenerated = StudyCard(
            id: target.id,
            syncId: target.id,
            noteId: nil,
            cardType: target.cardType,
            prompt: target.prompt,
            answer: target.answer.replacingObjectValues([
                "answerAudio": .object([
                    "url": .string("/api/study/media/healthy-answer"),
                ]),
            ]),
            state: target.state,
            answerAudioSource: "generated",
            createdAt: target.createdAt,
            updatedAt: target.updatedAt.addingTimeInterval(1)
        )
        let regeneratedData = try StorageCodec.encoder.encode(regenerated)
        let paths = LockedRequestPaths()
        let targetID = target.id
        let rejectedID = rejected.id
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path == "/api/study/cards/\(rejectedID)" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 422,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"message":"Rejected edit"}"#.utf8)
                )
            }
            if path.hasSuffix("/regenerate-answer-audio") {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    regeneratedData
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("healthy-audio".utf8)
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

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
    func testCreateReconcilesBackendNormalizedULIDWithoutDuplicate() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            let body = try requestBody(request)
            let createRequest = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let canonicalID = try XCTUnwrap(createRequest["id"] as? String).lowercased()
            let serverCard: [String: Any] = [
                "id": canonicalID,
                "syncId": canonicalID,
                "noteId": NSNull(),
                "cardType": try XCTUnwrap(createRequest["cardType"]),
                "prompt": try XCTUnwrap(createRequest["prompt"]),
                "answer": try XCTUnwrap(createRequest["answer"]),
                "state": [
                    "dueAt": NSNull(),
                    "introducedAt": NSNull(),
                    "failedAt": NSNull(),
                    "queueState": "new",
                    "scheduler": NSNull(),
                    "source": [:],
                ],
                "answerAudioSource": "missing",
                "createdAt": "2026-07-24T11:00:00Z",
                "updatedAt": "2026-07-24T11:00:00Z",
            ]
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONSerialization.data(withJSONObject: serverCard)
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        try await store.createCard(
            expression: "正規化",
            reading: "せいきか",
            meaning: "normalization"
        )

        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, records.first?.id.lowercased())
        XCTAssertEqual(store.libraryCards.count, 1)
        XCTAssertEqual(store.libraryCards.first?.id, records.first?.id)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
    }

    @MainActor
    func testCreateAcknowledgementPreservesQueuedEditWhenUpdateIsRejected() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let createAttempts = LockedCounter()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/cards":
                guard createAttempts.next() > 1 else {
                    throw URLError(.notConnectedToInternet)
                }
                let createRequest = try XCTUnwrap(
                    try JSONSerialization.jsonObject(
                        with: requestBody(request)
                    ) as? [String: Any]
                )
                let canonicalID = try XCTUnwrap(
                    createRequest["id"] as? String
                ).lowercased()
                let response: [String: Any] = [
                    "id": canonicalID,
                    "syncId": canonicalID,
                    "noteId": NSNull(),
                    "cardType": try XCTUnwrap(createRequest["cardType"]),
                    "prompt": try XCTUnwrap(createRequest["prompt"]),
                    "answer": try XCTUnwrap(createRequest["answer"]),
                    "state": [
                        "dueAt": NSNull(),
                        "introducedAt": NSNull(),
                        "failedAt": NSNull(),
                        "queueState": "new",
                        "scheduler": NSNull(),
                        "source": [:],
                    ],
                    "answerAudioSource": "missing",
                    "createdAt": "2026-07-24T11:00:00Z",
                    "updatedAt": "2026-07-24T11:00:00Z",
                ]
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    try JSONSerialization.data(withJSONObject: response)
                )
            default:
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 422,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"message":"Rejected update"}"#.utf8)
                )
            }
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        try await store.createCard(
            expression: "最初",
            reading: "さいしょ",
            meaning: "original"
        )
        let created = try XCTUnwrap(store.libraryCards.first)
        var editedDraft = StudyCardDraft(card: created)
        editedDraft.cueText = "編集済み"
        editedDraft.answerExpression = "編集済み"
        editedDraft.answerMeaning = "edited"
        try await store.updateCard(created, draft: editedDraft)

        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(record.id, created.id.lowercased())
        XCTAssertEqual(persisted.prompt["cueText"]?.stringValue, "編集済み")
        XCTAssertEqual(persisted.answer["meaning"]?.stringValue, "edited")
        XCTAssertNotNil(record.locallyUpdatedAt)
        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(pending.map(\.kind), ["cardUpdate"])
        XCTAssertEqual(pending.first?.resourceID, created.id.lowercased())
        XCTAssertNotNil(pending.first?.lastError)
    }

    @MainActor
    func testOlderUpdateAcknowledgementPreservesNewerRejectedEdit() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J000000000000000000000UE",
            expression: "元",
            masteryLevel: "guru"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let patchAttempts = LockedCounter()
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 0,
                reviewCount: 0,
                newCardsPerDay: 10,
                newCardsAvailableToday: 0
            ),
            cards: []
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let cardID = card.id
        let cardType = card.cardType
        let client = makeClient { request in
            guard request.url?.path != "/api/study/session/start" else {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    sessionData
                )
            }
            let attempt = patchAttempts.next()
            guard attempt > 2 else {
                throw URLError(.notConnectedToInternet)
            }
            guard attempt == 3 else {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 422,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"message":"Rejected newer update"}"#.utf8)
                )
            }
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: requestBody(request)
                ) as? [String: Any]
            )
            let response: [String: Any] = [
                "id": cardID,
                "syncId": cardID,
                "noteId": NSNull(),
                "cardType": cardType,
                "prompt": try XCTUnwrap(body["prompt"]),
                "answer": try XCTUnwrap(body["answer"]),
                "state": [
                    "dueAt": NSNull(),
                    "introducedAt": NSNull(),
                    "failedAt": NSNull(),
                    "queueState": "new",
                    "scheduler": NSNull(),
                    "source": [:],
                ],
                "answerAudioSource": "missing",
                "createdAt": "2026-07-24T11:00:00Z",
                "updatedAt": "2026-07-24T11:01:00Z",
            ]
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONSerialization.data(withJSONObject: response)
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        var firstDraft = StudyCardDraft(card: card)
        firstDraft.cueText = "一回目"
        firstDraft.answerExpression = "一回目"
        firstDraft.answerMeaning = "first"
        try await store.updateCard(card, draft: firstDraft)
        let firstEdit = try XCTUnwrap(store.libraryCards.first)
        var secondDraft = StudyCardDraft(card: firstEdit)
        secondDraft.cueText = "二回目"
        secondDraft.answerExpression = "二回目"
        secondDraft.answerMeaning = "second"
        try await store.updateCard(firstEdit, draft: secondDraft)

        await store.synchronize()

        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(persisted.prompt["cueText"]?.stringValue, "二回目")
        XCTAssertEqual(persisted.answer["meaning"]?.stringValue, "second")
        XCTAssertEqual(persisted.masteryLevel, "guru")
        XCTAssertNotNil(record.locallyUpdatedAt)
        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(pending.map(\.kind), ["cardUpdate"])
        XCTAssertNotNil(pending.first?.lastError)
    }

    @MainActor
    func testUpdateAcknowledgementPreservesPendingReviewMasteryProjection() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J000000000000000000000UR",
            expression: "Review pending",
            queueState: "review",
            scheduler: .object([
                "due": .string("2026-04-12T00:00:00.000Z"),
                "stability": .number(30),
                "difficulty": .number(6),
                "elapsed_days": .number(30),
                "scheduled_days": .number(30),
                "learning_steps": .number(0),
                "reps": .number(8),
                "lapses": .number(1),
                "state": .number(2),
                "last_review": .string("2026-03-13T00:00:00.000Z"),
            ]),
            masteryLevel: "guru"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()

        var draft = StudyCardDraft(card: card)
        draft.cueText = "Edited before review"
        let staleServerCard = StudyCard(
            id: card.id,
            syncId: card.id,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: draft.prompt(merging: card.prompt),
            answer: draft.answer(merging: card.answer),
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            masteryLevel: "guru",
            createdAt: card.createdAt,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let staleServerData = try StorageCodec.encoder.encode(staleServerCard)
        let patchAttempts = LockedCounter()
        let reviewAttempts = LockedCounter()
        let cardID = card.id
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/cards/\(cardID)":
                guard patchAttempts.next() > 1 else {
                    throw URLError(.notConnectedToInternet)
                }
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    staleServerData
                )
            case "/api/card-review-events/batch":
                _ = reviewAttempts.next()
                throw URLError(.notConnectedToInternet)
            default:
                throw URLError(.notConnectedToInternet)
            }
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )

        try await store.updateCard(card, draft: draft)
        let edited = try XCTUnwrap(store.libraryCards.first)
        let eventID = await store.recordReview(
            card: edited,
            rating: .good,
            duration: nil,
            reviewedAt: Date(timeIntervalSince1970: 1_500)
        )
        XCTAssertNotNil(eventID)
        let optimisticReview = try persistedCard(in: container)
        XCTAssertNil(optimisticReview.masteryLevel)

        await store.synchronize()

        let persisted = try persistedCard(in: container)
        XCTAssertEqual(persisted.prompt["cueText"]?.stringValue, "Edited before review")
        XCTAssertEqual(persisted.state, optimisticReview.state)
        XCTAssertNil(persisted.masteryLevel)
        XCTAssertEqual(patchAttempts.current, 2)
        XCTAssertGreaterThanOrEqual(reviewAttempts.current, 2)
    }

    @MainActor
    func testStaleEditorSnapshotSavesAgainstCanonicalLocalCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let clientID = "01J000000000000000000000SE"
        let canonicalID = clientID.lowercased()
        let staleCard = makeCard(id: clientID, expression: "同期前")
        let canonicalCard = StudyCard(
            id: canonicalID,
            syncId: canonicalID,
            noteId: staleCard.noteId,
            cardType: staleCard.cardType,
            prompt: staleCard.prompt,
            answer: staleCard.answer,
            state: staleCard.state,
            answerAudioSource: staleCard.answerAudioSource,
            createdAt: staleCard.createdAt,
            updatedAt: staleCard.updatedAt
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: canonicalCard,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(canonicalCard)
            )
        )
        try container.mainContext.save()
        let patchedPaths = LockedRequestPaths()
        let canonicalCardType = canonicalCard.cardType
        let canonicalAudioSource = canonicalCard.answerAudioSource
        let client = makeClient { request in
            patchedPaths.append(request.url?.path ?? "")
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: requestBody(request)
                ) as? [String: Any]
            )
            let response: [String: Any] = [
                "id": canonicalID,
                "syncId": canonicalID,
                "noteId": NSNull(),
                "cardType": canonicalCardType,
                "prompt": try XCTUnwrap(body["prompt"]),
                "answer": try XCTUnwrap(body["answer"]),
                "state": [
                    "dueAt": NSNull(),
                    "introducedAt": NSNull(),
                    "failedAt": NSNull(),
                    "queueState": "new",
                    "scheduler": NSNull(),
                    "source": [:],
                ],
                "answerAudioSource": canonicalAudioSource,
                "createdAt": "2026-07-24T11:00:00Z",
                "updatedAt": "2026-07-24T11:01:00Z",
            ]
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONSerialization.data(withJSONObject: response)
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        var draft = StudyCardDraft(card: staleCard)
        draft.cueText = "同期後"
        draft.answerExpression = "同期後"
        draft.answerMeaning = "after sync"

        try await store.updateCard(staleCard, draft: draft)

        XCTAssertEqual(patchedPaths.values, ["/api/study/cards/\(canonicalID)"])
        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, canonicalID)
        XCTAssertEqual(store.libraryCards.first?.prompt["cueText"]?.stringValue, "同期後")
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
    }

    @MainActor
    func testStaleEditorSyncAliasUpdatesCanonicalRecordWithoutDuplicate() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let staleCard = makeCard(
            id: "local-draft-id",
            syncId: "server-card-id",
            expression: "before sync"
        )
        let canonicalCard = StudyCard(
            id: "server-card-id",
            syncId: "server-card-id",
            noteId: staleCard.noteId,
            cardType: staleCard.cardType,
            prompt: staleCard.prompt,
            answer: staleCard.answer,
            state: staleCard.state,
            answerAudioSource: staleCard.answerAudioSource,
            createdAt: staleCard.createdAt,
            updatedAt: staleCard.updatedAt
        )
        container.mainContext.insert(LocalCardRecord(
            card: canonicalCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(canonicalCard)
        ))
        try container.mainContext.save()
        let patchedPaths = LockedRequestPaths()
        let client = makeClient { request in
            patchedPaths.append(request.url?.path ?? "")
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )
        var draft = StudyCardDraft(card: staleCard)
        draft.cueText = "edited after sync"

        try await store.updateCard(staleCard, draft: draft)

        XCTAssertEqual(patchedPaths.values, ["/api/study/cards/server-card-id"])
        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, "server-card-id")
        let persisted = try XCTUnwrap(records.first).payload
        XCTAssertEqual(
            try StorageCodec.decoder.decode(StudyCard.self, from: persisted).promptText,
            "edited after sync"
        )
    }

    @MainActor
    func testStaleEditorSnapshotDeletesCanonicalLocalCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let clientID = "01J000000000000000000000SD"
        let canonicalID = clientID.lowercased()
        let staleCard = makeCard(id: clientID, expression: "削除")
        let canonicalCard = StudyCard(
            id: canonicalID,
            syncId: canonicalID,
            noteId: staleCard.noteId,
            cardType: staleCard.cardType,
            prompt: staleCard.prompt,
            answer: staleCard.answer,
            state: staleCard.state,
            answerAudioSource: staleCard.answerAudioSource,
            createdAt: staleCard.createdAt,
            updatedAt: staleCard.updatedAt
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: canonicalCard,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(canonicalCard)
            )
        )
        try container.mainContext.save()
        let deletedPaths = LockedRequestPaths()
        let client = makeClient { request in
            deletedPaths.append(request.url?.path ?? "")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        try await store.deleteCard(staleCard)

        XCTAssertEqual(deletedPaths.values, ["/api/study/cards/\(canonicalID)"])
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(store.libraryCards.isEmpty)
    }

    @MainActor
    func testNormalizedCreateRewritesQueuedReviewToCanonicalCardID() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let createAttempts = LockedCounter()
        let postedReviewCardIDs = LockedRequestPaths()
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 0,
                reviewCount: 0,
                newCardsPerDay: 10,
                newCardsAvailableToday: 0
            ),
            cards: []
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/cards":
                guard createAttempts.next() > 2 else {
                    throw URLError(.notConnectedToInternet)
                }
                let createRequest = try XCTUnwrap(
                    try JSONSerialization.jsonObject(
                        with: requestBody(request)
                    ) as? [String: Any]
                )
                let canonicalID = try XCTUnwrap(
                    createRequest["id"] as? String
                ).lowercased()
                let response: [String: Any] = [
                    "id": canonicalID,
                    "syncId": canonicalID,
                    "noteId": NSNull(),
                    "cardType": try XCTUnwrap(createRequest["cardType"]),
                    "prompt": try XCTUnwrap(createRequest["prompt"]),
                    "answer": try XCTUnwrap(createRequest["answer"]),
                    "state": [
                        "dueAt": NSNull(),
                        "introducedAt": NSNull(),
                        "failedAt": NSNull(),
                        "queueState": "new",
                        "scheduler": NSNull(),
                        "source": [:],
                    ],
                    "answerAudioSource": "missing",
                    "createdAt": "2026-07-24T11:00:00Z",
                    "updatedAt": "2026-07-24T11:00:00Z",
                ]
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    try JSONSerialization.data(withJSONObject: response)
                )
            case "/api/card-review-events/batch":
                let body = try XCTUnwrap(
                    try JSONSerialization.jsonObject(
                        with: requestBody(request)
                    ) as? [String: Any]
                )
                let events = try XCTUnwrap(body["events"] as? [[String: Any]])
                postedReviewCardIDs.append(
                    try XCTUnwrap(events.first?["card_id"] as? String)
                )
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data("{}".utf8)
                )
            case "/api/study/session/start":
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    sessionData
                )
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        try await store.createCard(expression: "同期", reading: "どうき", meaning: "sync")
        let clientCard = try XCTUnwrap(store.cards.first)
        await store.recordReview(card: clientCard, rating: .good, duration: nil)

        XCTAssertEqual(
            Set(
                try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                    .map(\.kind)
            ),
            ["cardCreate", "review"]
        )

        await store.synchronize()

        XCTAssertEqual(postedReviewCardIDs.values, [clientCard.id.lowercased()])
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertEqual(store.libraryCards.first?.id, clientCard.id.lowercased())
    }

    @MainActor
    func testCreateReconciliationKeepsReviewedCanonicalDuplicateState() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let clientID = "01J000000000000000000000RA"
        let serverID = clientID.lowercased()
        let staleClientCard = makeCard(
            id: clientID,
            expression: "同期",
            queueState: "new"
        )
        let canonicalServerCard = StudyCard(
            id: serverID,
            syncId: serverID,
            noteId: staleClientCard.noteId,
            cardType: staleClientCard.cardType,
            prompt: staleClientCard.prompt,
            answer: staleClientCard.answer,
            state: staleClientCard.state,
            answerAudioSource: staleClientCard.answerAudioSource,
            createdAt: staleClientCard.createdAt,
            updatedAt: staleClientCard.updatedAt.addingTimeInterval(1)
        )
        let clientRecord = LocalCardRecord(
            card: staleClientCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(staleClientCard)
        )
        clientRecord.locallyUpdatedAt = staleClientCard.updatedAt
        let serverRecord = LocalCardRecord(
            card: canonicalServerCard,
            userID: 1,
            queueIndex: 1,
            payload: try StorageCodec.encoder.encode(canonicalServerCard)
        )
        container.mainContext.insert(clientRecord)
        container.mainContext.insert(serverRecord)
        let createRequest = CreateStudyCardRequest(
            id: clientID,
            cardType: staleClientCard.cardType,
            prompt: staleClientCard.prompt,
            answer: staleClientCard.answer
        )
        container.mainContext.insert(
            PendingMutation(
                kind: "cardCreate",
                userID: 1,
                resourceID: clientID,
                payload: try StorageCodec.encoder.encode(createRequest)
            )
        )
        try container.mainContext.save()

        let serverCardData = try StorageCodec.encoder.encode(canonicalServerCard)
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/cards":
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    serverCardData
                )
            case "/api/card-review-events/batch", "/api/study/session/start":
                throw URLError(.notConnectedToInternet)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        await store.recordReview(card: canonicalServerCard, rating: .good, duration: nil)
        let reviewedCard = try XCTUnwrap(
            store.libraryCards.first { $0.id == serverID }
        )

        await store.synchronize()

        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, serverID)
        let persisted = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: try XCTUnwrap(records.first?.payload)
        )
        XCTAssertEqual(persisted.state.queueState, reviewedCard.state.queueState)
        XCTAssertEqual(persisted.state.scheduler, reviewedCard.state.scheduler)
        XCTAssertEqual(
            try XCTUnwrap(persisted.state.dueAt).timeIntervalSince1970,
            try XCTUnwrap(reviewedCard.state.dueAt).timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(
            try XCTUnwrap(persisted.state.introducedAt).timeIntervalSince1970,
            try XCTUnwrap(reviewedCard.state.introducedAt).timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertFalse(try XCTUnwrap(records.first).isInActiveSession)
        XCTAssertTrue(store.cards.allSatisfy { $0.id != serverID })
        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(pending.map(\.kind), ["review"])
        XCTAssertEqual(pending.first?.resourceID, serverID)
    }

    @MainActor
    func testPitchAccentResolutionPersistsServerEnrichmentWithoutChangingSchedule() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let original = makeCard(
            id: "compatibility-card-id",
            expression: "会社"
        )
        let card = StudyCard(
            id: original.id,
            syncId: "01J000000000000000000000PA",
            noteId: original.noteId,
            cardType: original.cardType,
            prompt: original.prompt,
            answer: original.answer,
            state: original.state,
            answerAudioSource: original.answerAudioSource,
            masteryLevel: "guru",
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()

        let resolvedAnswer = card.answer.replacingObjectValues([
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
        let serverCard = StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: resolvedAnswer,
            state: .init(
                dueAt: .distantFuture,
                introducedAt: .now,
                failedAt: .now,
                queueState: "relearning",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: .now
        )
        let responseData = try StorageCodec.encoder.encode(serverCard)
        let client = makeClient { request in
            XCTAssertEqual(
                request.url?.path,
                "/api/study/cards/01J000000000000000000000PA/pitch-accent"
            )
            XCTAssertEqual(request.httpMethod, "POST")
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
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        await store.resolvePitchAccent(for: card)

        let updated = try XCTUnwrap(store.cards.first)
        XCTAssertEqual(updated.state, card.state)
        XCTAssertEqual(updated.masteryLevel, "guru")
        XCTAssertEqual(updated.presentation.back.pitchAccent?.reading, "かいしゃ")
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(persisted.masteryLevel, "guru")
        XCTAssertEqual(persisted.presentation.back.pitchAccent?.pattern, [0, 1, 1])
    }

    @MainActor
    func testPersistedUnresolvedPitchAccentDoesNotRetryOnEveryReveal() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let original = makeCard(
            id: "01J000000000000000000000PU",
            expression: "固有名詞"
        )
        let card = StudyCard(
            id: original.id,
            syncId: original.syncId,
            noteId: original.noteId,
            cardType: original.cardType,
            prompt: original.prompt,
            answer: original.answer.replacingObjectValues([
                "pitchAccent": .object([
                    "status": .string("unresolved"),
                    "reason": .string("not-found"),
                ]),
            ]),
            state: original.state,
            answerAudioSource: original.answerAudioSource,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let requestCount = LockedCounter()
        let client = makeClient { _ in
            _ = requestCount.next()
            throw URLError(.badServerResponse)
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        await store.resolvePitchAccent(for: card)
        await store.resolvePitchAccent(for: card)

        XCTAssertEqual(requestCount.current, 0)
        XCTAssertNil(store.cards.first?.presentation.back.pitchAccent)
    }

    @MainActor
    func testPitchAccentResolutionPreservesReviewThatFinishesDuringRequest() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J000000000000000000000PR",
            expression: "会社"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let serverCard = cardWithResolvedPitchAccent(card)
        let responseData = try StorageCodec.encoder.encode(serverCard)
        let gate = LockedRequestGate()
        let client = makeDelayedPitchClient(responseData: responseData, gate: gate)
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        let resolution = Task { await store.resolvePitchAccent(for: card) }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)
        let reviewedAt = Date.now
        let reviewed = try card.applyingReview(.good, at: reviewedAt)
        let reviewedCard = StudyCard(
            id: reviewed.id,
            syncId: reviewed.syncId,
            noteId: reviewed.noteId,
            cardType: reviewed.cardType,
            prompt: reviewed.prompt.replacingObjectValues([
                "cueText": .string("編集した会社"),
            ]),
            answer: reviewed.answer.replacingObjectValues([
                "meaning": .string("edited company"),
            ]),
            state: reviewed.state,
            answerAudioSource: reviewed.answerAudioSource,
            createdAt: reviewed.createdAt,
            updatedAt: reviewedAt
        )
        let reviewedRecord = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        reviewedRecord.payload = try StorageCodec.encoder.encode(reviewedCard)
        reviewedRecord.isInActiveSession = false
        reviewedRecord.locallyUpdatedAt = reviewedAt
        try container.mainContext.save()
        gate.release()
        await resolution.value

        let persisted = try persistedCard(in: container)
        XCTAssertEqual(persisted.state.queueState, reviewedCard.state.queueState)
        XCTAssertEqual(persisted.state.scheduler, reviewedCard.state.scheduler)
        XCTAssertEqual(
            try XCTUnwrap(persisted.state.dueAt).timeIntervalSince1970,
            try XCTUnwrap(reviewedCard.state.dueAt).timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(persisted.presentation.back.pitchAccent?.reading, "かいしゃ")
        XCTAssertEqual(persisted.prompt["cueText"]?.stringValue, "編集した会社")
        XCTAssertEqual(persisted.answer["meaning"]?.stringValue, "edited company")
        XCTAssertFalse(
            try XCTUnwrap(
                container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
            ).isInActiveSession
        )
        XCTAssertNotNil(
            try XCTUnwrap(
                container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
            ).locallyUpdatedAt
        )
    }

    @MainActor
    func testPitchAccentResolutionDoesNotResurrectCardDeletedDuringRequest() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J000000000000000000000PD",
            expression: "会社"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let responseData = try StorageCodec.encoder.encode(cardWithResolvedPitchAccent(card))
        let gate = LockedRequestGate()
        let client = makeDelayedPitchClient(responseData: responseData, gate: gate)
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        let resolution = Task { await store.resolvePitchAccent(for: card) }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)
        container.mainContext.insert(
            PendingMutation(kind: "cardDelete", userID: 1, resourceID: card.id, payload: Data())
        )
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        container.mainContext.delete(record)
        try container.mainContext.save()
        gate.release()
        await resolution.value

        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
    }
}
