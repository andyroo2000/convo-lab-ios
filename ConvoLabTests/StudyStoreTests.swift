import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

final class StudyStoreTests: XCTestCase {
    @MainActor
    func testNewCardQueueRefreshAndReorderUseCompatibilityAPI() async throws {
        let firstID = "01J00000000000000000000001"
        let secondID = "01J00000000000000000000002"
        let queueResponse: @Sendable (String, String) -> Data = { first, second in
            Data(
                """
                {
                  "items": [
                    {
                      "id": "\(first)",
                      "noteId": "\(first)",
                      "cardType": "recognition",
                      "displayText": "\(first == firstID ? "犬" : "猫")",
                      "meaning": "\(first == firstID ? "dog" : "cat")",
                      "queuePosition": 1,
                      "createdAt": "2026-07-25T12:00:00.000Z",
                      "updatedAt": "2026-07-25T12:00:00.000Z"
                    },
                    {
                      "id": "\(second)",
                      "noteId": "\(second)",
                      "cardType": "recognition",
                      "displayText": "\(second == secondID ? "猫" : "犬")",
                      "meaning": "\(second == secondID ? "cat" : "dog")",
                      "queuePosition": 2,
                      "createdAt": "2026-07-25T12:00:00.000Z",
                      "updatedAt": "2026-07-25T12:00:00.000Z"
                    }
                  ],
                  "total": 2,
                  "limit": 100,
                  "nextCursor": null
                }
                """.utf8
            )
        }
        let client = makeClient { request in
            let path = request.url?.path
            if path == "/api/study/new-queue" {
                XCTAssertEqual(request.url?.query, "limit=100")
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    queueResponse(firstID, secondID)
                )
            }

            XCTAssertEqual(path, "/api/study/new-queue/reorder")
            XCTAssertEqual(request.httpMethod, "POST")
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            )
            XCTAssertEqual(object["cardIds"] as? [String], [secondID, firstID])
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                queueResponse(secondID, firstID)
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
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

        try await store.refreshNewCardQueue()

        XCTAssertEqual(store.newCardQueue.map(\.id), [firstID, secondID])
        XCTAssertEqual(store.newCardQueueTotal, 2)

        try await store.moveNewCards(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertEqual(store.newCardQueue.map(\.id), [secondID, firstID])
        XCTAssertEqual(store.newCardQueue.map(\.queuePosition), [1, 2])
    }

    @MainActor
    func testCardLibraryLoadsQueueAndAllCardsAcrossCursorPagesWithoutDuplicates() async throws {
        let firstCard = makeCard(id: "01J00000000000000000000011", expression: "犬")
        let secondCard = makeCard(id: "01J00000000000000000000012", expression: "猫")
        let firstQueueItem = StudyNewCardQueueItem(
            id: firstCard.id,
            noteId: firstCard.id,
            cardType: "recognition",
            displayText: "犬",
            meaning: "dog",
            queuePosition: 1,
            createdAt: .now,
            updatedAt: .now
        )
        let secondQueueItem = StudyNewCardQueueItem(
            id: secondCard.id,
            noteId: secondCard.id,
            cardType: "recognition",
            displayText: "猫",
            meaning: "cat",
            queuePosition: 2,
            createdAt: .now,
            updatedAt: .now
        )
        let firstQueuePage = try StorageCodec.encoder.encode(
            StudyNewCardQueueResponse(
                items: [firstQueueItem],
                total: 2,
                limit: 100,
                nextCursor: "1"
            )
        )
        let secondQueuePage = try StorageCodec.encoder.encode(
            StudyNewCardQueueResponse(
                items: [firstQueueItem, secondQueueItem],
                total: 2,
                limit: 100,
                nextCursor: nil
            )
        )
        let firstCardPage = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [firstCard], limit: 50, nextCursor: "cards-2")
        )
        let secondCardPage = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [firstCard, secondCard], limit: 50, nextCursor: nil)
        )
        let client = makeClient { request in
            let query = request.url?.query ?? ""
            let data: Data
            switch (request.url?.path, query) {
            case ("/api/study/new-queue", "limit=100"):
                data = firstQueuePage
            case ("/api/study/new-queue", "cursor=1&limit=100"):
                data = secondQueuePage
            case ("/api/study/cards", "per_page=50"):
                data = firstCardPage
            case ("/api/study/cards", "cursor=cards-2&per_page=50"):
                data = secondCardPage
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        try await store.refreshNewCardQueue()
        try await store.loadMoreNewCardQueue()
        try await store.refreshAllCards()
        try await store.loadMoreAllCards()

        XCTAssertEqual(store.newCardQueue.map(\.id), [firstCard.id, secondCard.id])
        XCTAssertNil(store.newCardQueueNextCursor)
        XCTAssertEqual(store.allCards.map(\.id), [firstCard.id, secondCard.id])
        XCTAssertNil(store.allCardsNextCursor)
    }

    @MainActor
    func testAudioRecognitionDraftCommitEmbedsPromptAudioAndPersistsCanonicalCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let audio: JSONValue = .object([
            "id": .string("audio-1"),
            "filename": .string("audio-1.mp3"),
            "url": .string("/api/study/media/audio-1"),
            "mediaKind": .string("audio"),
            "source": .string("generated"),
        ])
        let now = Date.now
        let serverDraft = StudyManualCardDraft(
            id: "01J0000000000000000000000DR",
            status: "ready",
            committedCardId: nil,
            creationKind: .audioRecognition,
            cardType: "recognition",
            prompt: .object([
                "serverEnrichment": .object(["source": .string("learning-os")]),
            ]),
            answer: .object([
                "expression": .string("営業の仕事は楽しいです。"),
                "meaning": .string("Sales work is fun."),
                "pitchAccent": .array([.number(2)]),
            ]),
            imagePlacement: .none,
            imagePrompt: nil,
            previewAudio: audio,
            previewAudioRole: "prompt",
            previewImage: nil,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now
        )
        let card = StudyCard(
            id: "01j0000000000000000000000cd",
            syncId: "01j0000000000000000000000cd",
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueAudio": audio]),
            answer: serverDraft.answer.replacingObjectValues(["answerAudio": audio]),
            state: .init(
                dueAt: nil,
                introducedAt: nil,
                failedAt: nil,
                queueState: "new",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "generated",
            createdAt: now,
            updatedAt: now
        )
        let serverDraftData = try StorageCodec.encoder.encode(serverDraft)
        let committedData = try StorageCodec.encoder.encode(card)
        let paths = LockedRequestPaths()
        let commitIDs = LockedRequestPaths()
        let deleteAttempts = LockedCounter()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path == "/api/study/card-drafts" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    serverDraftData
                )
            }
            if request.httpMethod == "PATCH" {
                let body = try requestBody(request)
                let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                let prompt = payload?["prompt"] as? [String: Any]
                let answer = payload?["answer"] as? [String: Any]
                XCTAssertEqual(
                    (prompt?["serverEnrichment"] as? [String: Any])?["source"] as? String,
                    "learning-os"
                )
                XCTAssertEqual(answer?["pitchAccent"] as? [Int], [2])
                XCTAssertEqual((prompt?["cueAudio"] as? [String: Any])?["id"] as? String, "audio-1")
                XCTAssertEqual(
                    (answer?["answerAudio"] as? [String: Any])?["id"] as? String,
                    "audio-1"
                )
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    serverDraftData
                )
            }
            if path.hasSuffix("/create-card") {
                let body = try requestBody(request)
                let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                XCTAssertEqual((payload?["id"] as? String)?.count, 26)
                commitIDs.append(payload?["id"] as? String ?? "")
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    committedData
                )
            }
            if request.httpMethod == "DELETE" {
                if deleteAttempts.next() == 1 {
                    return (
                        HTTPURLResponse(
                            url: request.url!,
                            statusCode: 409,
                            httpVersion: nil,
                            headerFields: ["Content-Type": "application/json"]
                        )!,
                        Data(#"{"message":"cleanup failed"}"#.utf8)
                    )
                }
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 410,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"message":"draft gone"}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("draft-audio".utf8)
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        var draft = StudyCardDraft(cardType: .recognition)
        draft.isAudioLedPrompt = true
        draft.isMediaLedPrompt = true
        draft.answerExpression = "営業の仕事は楽しいです。"
        draft.answerMeaning = "Sales work is fun."

        let queued = try await store.queueManualDraft(
            creationKind: .audioRecognition,
            draft: draft
        )
        do {
            try await store.createCard(
                from: queued,
                draft: draft,
                previewAudio: audio,
                previewAudioRole: "prompt",
                previewImage: nil
            )
            XCTFail("Expected the first draft cleanup to fail")
        } catch let APIClientError.rejected(status, message) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(message, "cleanup failed")
        }
        XCTAssertEqual(store.libraryCards.map(\.id), [card.id])
        XCTAssertFalse(store.manualDrafts.isEmpty)
        XCTAssertTrue(store.hasPendingDraftCommit(for: serverDraft.id))
        XCTAssertEqual(store.quarantinedMutationCount, 0)
        do {
            try await store.deleteManualDraft(queued)
            XCTFail("Expected ambiguous draft commits to block deletion")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "This draft may already have created a card. Retry Create Card or sync before deleting it."
            )
        }

        try await store.retryPendingDraftCommits()

        XCTAssertEqual(
            paths.values,
            [
                "/api/study/card-drafts",
                "/api/study/card-drafts/\(serverDraft.id)",
                "/api/study/card-drafts/\(serverDraft.id)/create-card",
                "/api/study/media/audio-1",
                "/api/study/card-drafts/\(serverDraft.id)",
                "/api/study/card-drafts/\(serverDraft.id)/create-card",
                "/api/study/card-drafts/\(serverDraft.id)",
            ]
        )
        XCTAssertEqual(commitIDs.values.count, 2)
        XCTAssertEqual(commitIDs.values[0], commitIDs.values[1])
        XCTAssertTrue(store.manualDrafts.isEmpty)
        XCTAssertEqual(store.libraryCards.map(\.id), [card.id])
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                .allSatisfy { $0.kind != "draftCommit" }
        )
        let persisted = try persistedCard(in: container)
        XCTAssertEqual(persisted.prompt["cueAudio"], audio)
        XCTAssertEqual(persisted.answer["answerAudio"], audio)
    }

    @MainActor
    func testDraftCommitRetryContinuesAfterAnUnrelatedFailure() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let firstDraftID = "01J0000000000000000000000F1"
        let secondDraftID = "01J0000000000000000000000F2"
        let firstCardID = "01J0000000000000000000000C1"
        let secondCardID = "01J0000000000000000000000C2"
        let firstMutation = PendingMutation(
            kind: "draftCommit",
            userID: 1,
            resourceID: firstDraftID,
            payload: try StorageCodec.encoder.encode(
                CreateCardFromStudyManualDraftRequest(id: firstCardID)
            )
        )
        let secondMutation = PendingMutation(
            kind: "draftCommit",
            userID: 1,
            resourceID: secondDraftID,
            payload: try StorageCodec.encoder.encode(
                CreateCardFromStudyManualDraftRequest(id: secondCardID)
            )
        )
        secondMutation.createdAt = firstMutation.createdAt.addingTimeInterval(1)
        container.mainContext.insert(firstMutation)
        container.mainContext.insert(secondMutation)
        try container.mainContext.save()

        let committedCard = makeCard(
            id: secondCardID.lowercased(),
            expression: "二番目"
        )
        let committedData = try StorageCodec.encoder.encode(committedCard)
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.contains(firstDraftID) {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 500,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"message":"first draft failed"}"#.utf8)
                )
            }
            if path.hasSuffix("/create-card") {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    committedData
                )
            }
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

        do {
            try await store.retryPendingDraftCommits()
            XCTFail("Expected the first draft failure to be reported")
        } catch let APIClientError.rejected(status, message) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(message, "first draft failed")
        }

        XCTAssertEqual(
            paths.values,
            [
                "/api/study/card-drafts/\(firstDraftID)/create-card",
                "/api/study/card-drafts/\(secondDraftID)/create-card",
                "/api/study/card-drafts/\(secondDraftID)",
            ]
        )
        XCTAssertEqual(store.libraryCards.map(\.id), [committedCard.id])
        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(pending.map(\.resourceID), [firstDraftID])
        XCTAssertEqual(pending.first?.attemptCount, 1)
        XCTAssertNil(pending.first?.lastError)

        for _ in 0..<2 {
            do {
                try await store.retryPendingDraftCommits()
                XCTFail("Expected the remaining draft retry to fail")
            } catch let APIClientError.rejected(status, _) {
                XCTAssertEqual(status, 500)
            }
        }
        let retrying = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>()).first
        )
        XCTAssertEqual(retrying.attemptCount, 3)
        XCTAssertNil(retrying.lastError)
        XCTAssertEqual(store.quarantinedMutationCount, 0)
    }

    @MainActor
    func testTransientDraftCommitFailuresKeepTheirClientCardID() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000R1"
        let clientCardID = "01J0000000000000000000000R2"
        let now = Date.now
        let serverDraft = StudyManualCardDraft(
            id: draftID,
            status: "ready",
            committedCardId: nil,
            creationKind: .audioRecognition,
            cardType: "recognition",
            prompt: .object([:]),
            answer: .object(["expression": .string("再試行")]),
            imagePlacement: .none,
            imagePrompt: nil,
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now
        )
        let committedCard = makeCard(
            id: clientCardID.lowercased(),
            expression: "再試行"
        )
        let serverDraftData = try StorageCodec.encoder.encode(serverDraft)
        let committedData = try StorageCodec.encoder.encode(committedCard)
        let mutation = PendingMutation(
            kind: "draftCommit",
            userID: 1,
            resourceID: draftID,
            payload: try StorageCodec.encoder.encode(
                CreateCardFromStudyManualDraftRequest(id: clientCardID)
            )
        )
        container.mainContext.insert(mutation)
        try container.mainContext.save()
        let createAttempts = LockedCounter()
        let commitIDs = LockedRequestPaths()
        let client = makeClient { request in
            if request.url?.path.hasSuffix("/create-card") == true {
                let body = try requestBody(request)
                let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                commitIDs.append(payload?["id"] as? String ?? "")
                let attempt = createAttempts.next()
                if attempt == 1 {
                    return (
                        HTTPURLResponse(
                            url: request.url!,
                            statusCode: 429,
                            httpVersion: nil,
                            headerFields: ["Content-Type": "application/json"]
                        )!,
                        Data(#"{"message":"try later"}"#.utf8)
                    )
                }
                if attempt == 2 {
                    return (
                        HTTPURLResponse(
                            url: request.url!,
                            statusCode: 409,
                            httpVersion: nil,
                            headerFields: ["Content-Type": "application/json"]
                        )!,
                        Data(
                            #"{"message":"Generating drafts cannot create cards yet."}"#.utf8
                        )
                    )
                }
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    committedData
                )
            }
            if request.httpMethod == "GET" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    serverDraftData
                )
            }
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
        var draft = StudyCardDraft(cardType: .recognition)
        draft.isAudioLedPrompt = true
        draft.isMediaLedPrompt = true
        draft.answerExpression = "再試行"

        do {
            try await store.createCard(
                from: serverDraft,
                draft: draft,
                previewAudio: nil,
                previewAudioRole: nil,
                previewImage: nil
            )
            XCTFail("Expected the first commit to be rate limited")
        } catch let APIClientError.rejected(status, _) {
            XCTAssertEqual(status, 429)
        }
        XCTAssertEqual(store.draftCommitRecoveryState(for: draftID), .outcomeUnknown)
        XCTAssertNil(mutation.lastError)

        do {
            try await store.retryPendingDraftCommits()
            XCTFail("Expected the still-generating conflict")
        } catch let APIClientError.rejected(status, _) {
            XCTAssertEqual(status, 409)
        }
        XCTAssertEqual(store.draftCommitRecoveryState(for: draftID), .outcomeUnknown)
        XCTAssertEqual(mutation.kind, "draftCommit")
        XCTAssertNil(mutation.lastError)

        try await store.createCard(
            from: serverDraft,
            draft: draft,
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil
        )

        XCTAssertEqual(commitIDs.values, [clientCardID, clientCardID, clientCardID])
        XCTAssertFalse(store.hasPendingDraftCommit(for: draftID))
        XCTAssertEqual(store.libraryCards.map(\.id), [committedCard.id])
        XCTAssertEqual(store.libraryCards.first?.id, commitIDs.values.last?.lowercased())
    }

    @MainActor
    func testDifferentCommittedCardIDConflictIsPermanentlyRejectedFromDraftState() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000K1"
        let clientCardID = "01J0000000000000000000000K2"
        let conflictingCardID = "01J0000000000000000000000K3"
        let serverDraft = StudyManualCardDraft(
            id: draftID,
            status: "ready",
            committedCardId: conflictingCardID.lowercased(),
            creationKind: .audioRecognition,
            cardType: "recognition",
            prompt: .object([:]),
            answer: .object(["expression": .string("競合")]),
            imagePlacement: .none,
            imagePrompt: nil,
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil,
            errorMessage: nil,
            createdAt: .now,
            updatedAt: .now
        )
        let serverDraftData = try StorageCodec.encoder.encode(serverDraft)
        let mutation = PendingMutation(
            kind: "draftCommit",
            userID: 1,
            resourceID: draftID,
            payload: try StorageCodec.encoder.encode(
                CreateCardFromStudyManualDraftRequest(id: clientCardID)
            )
        )
        container.mainContext.insert(mutation)
        try container.mainContext.save()
        let client = makeClient { request in
            if request.httpMethod == "GET" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    serverDraftData
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 409,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"message":"conflict"}"#.utf8)
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        do {
            try await store.retryPendingDraftCommits()
            XCTFail("Expected a different-card-ID conflict")
        } catch let APIClientError.rejected(status, _) {
            XCTAssertEqual(status, 409)
        }

        XCTAssertEqual(store.draftCommitRecoveryState(for: draftID), .rejected)
        XCTAssertEqual(mutation.kind, "draftCommitRejected")
        XCTAssertNotNil(mutation.lastError)
        XCTAssertEqual(store.manualDrafts.first?.committedCardId, conflictingCardID.lowercased())
    }

    @MainActor
    func testRejectedDraftCommitCanBeEditedAndRetriedWithSameID() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000V1"
        let clientCardID = "01J0000000000000000000000V2"
        let now = Date.now
        let serverDraft = StudyManualCardDraft(
            id: draftID,
            status: "ready",
            committedCardId: nil,
            creationKind: .productionImage,
            cardType: "production",
            prompt: .object([:]),
            answer: .object(["expression": .string("修正前")]),
            imagePlacement: .prompt,
            imagePrompt: "before",
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now
        )
        let correctedDraft = StudyManualCardDraft(
            id: draftID,
            status: "ready",
            committedCardId: nil,
            creationKind: .productionImage,
            cardType: "production",
            prompt: .object([:]),
            answer: .object(["expression": .string("修正後")]),
            imagePlacement: .prompt,
            imagePrompt: "after",
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now
        )
        let committedCard = makeCard(
            id: clientCardID.lowercased(),
            expression: "修正後"
        )
        let correctedData = try StorageCodec.encoder.encode(correctedDraft)
        let committedData = try StorageCodec.encoder.encode(committedCard)
        let mutation = PendingMutation(
            kind: "draftCommit",
            userID: 1,
            resourceID: draftID,
            payload: try StorageCodec.encoder.encode(
                CreateCardFromStudyManualDraftRequest(id: clientCardID)
            )
        )
        container.mainContext.insert(mutation)
        try container.mainContext.save()
        let createAttempts = LockedCounter()
        let commitIDs = LockedRequestPaths()
        let patchedExpressions = LockedRequestPaths()
        let client = makeClient { request in
            if request.httpMethod == "PATCH" {
                let body = try requestBody(request)
                let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                let answer = payload?["answer"] as? [String: Any]
                patchedExpressions.append(answer?["expression"] as? String ?? "")
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    correctedData
                )
            }
            if request.url?.path.hasSuffix("/create-card") == true {
                let body = try requestBody(request)
                let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                commitIDs.append(payload?["id"] as? String ?? "")
                if createAttempts.next() == 1 {
                    return (
                        HTTPURLResponse(
                            url: request.url!,
                            statusCode: 422,
                            httpVersion: nil,
                            headerFields: ["Content-Type": "application/json"]
                        )!,
                        Data(#"{"message":"fix the draft"}"#.utf8)
                    )
                }
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    committedData
                )
            }
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
        var draft = StudyCardDraft(cardType: .production)
        draft.isMediaLedPrompt = true
        draft.imagePlacement = .prompt
        draft.imagePrompt = "before"
        draft.answerExpression = "修正前"

        do {
            try await store.createCard(
                from: serverDraft,
                draft: draft,
                previewAudio: nil,
                previewAudioRole: nil,
                previewImage: nil
            )
            XCTFail("Expected validation rejection")
        } catch let APIClientError.rejected(status, _) {
            XCTAssertEqual(status, 422)
        }
        XCTAssertEqual(store.draftCommitRecoveryState(for: draftID), .rejected)
        XCTAssertEqual(mutation.kind, "draftCommitRejected")
        XCTAssertNotNil(mutation.lastError)

        draft.imagePrompt = "after"
        draft.answerExpression = "修正後"
        try await store.createCard(
            from: serverDraft,
            draft: draft,
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil
        )

        XCTAssertEqual(patchedExpressions.values, ["修正後"])
        XCTAssertEqual(commitIDs.values, [clientCardID, clientCardID])
        XCTAssertFalse(store.hasPendingDraftCommit(for: draftID))
    }

    @MainActor
    func testRejectedDraftCommitCanBeDeletedSafely() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000D1"
        let serverDraft = StudyManualCardDraft(
            id: draftID,
            status: "ready",
            committedCardId: nil,
            creationKind: .audioRecognition,
            cardType: "recognition",
            prompt: .object([:]),
            answer: .object(["expression": .string("削除")]),
            imagePlacement: .none,
            imagePrompt: nil,
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil,
            errorMessage: nil,
            createdAt: .now,
            updatedAt: .now
        )
        let mutation = PendingMutation(
            kind: "draftCommitRejected",
            userID: 1,
            resourceID: draftID,
            payload: try StorageCodec.encoder.encode(
                CreateCardFromStudyManualDraftRequest(
                    id: "01J0000000000000000000000D2"
                )
            )
        )
        mutation.lastError = "HTTP 422: rejected"
        container.mainContext.insert(mutation)
        try container.mainContext.save()
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            paths.append(request.url?.path ?? "")
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

        try await store.deleteManualDraft(serverDraft)

        XCTAssertEqual(paths.values, ["/api/study/card-drafts/\(draftID)"])
        XCTAssertFalse(store.hasPendingDraftCommit(for: draftID))
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
    }

    @MainActor
    func testManualDraftRefreshConsumesEveryCursorPage() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let now = Date.now
        func makeDraft(_ id: String) -> StudyManualCardDraft {
            StudyManualCardDraft(
                id: id,
                status: "ready",
                committedCardId: nil,
                creationKind: .audioRecognition,
                cardType: "recognition",
                prompt: .object([:]),
                answer: .object(["expression": .string(id)]),
                imagePlacement: .none,
                imagePrompt: nil,
                previewAudio: nil,
                previewAudioRole: nil,
                previewImage: nil,
                errorMessage: nil,
                createdAt: now,
                updatedAt: now
            )
        }
        let firstDraft = makeDraft("01J0000000000000000000000P1")
        let secondDraft = makeDraft("01J0000000000000000000000P2")
        let firstPage = try StorageCodec.encoder.encode(
            StudyManualCardDraftListResponse(
                drafts: [firstDraft],
                total: 2,
                limit: 200,
                nextCursor: "next-page"
            )
        )
        let secondPage = try StorageCodec.encoder.encode(
            StudyManualCardDraftListResponse(
                drafts: [secondDraft],
                total: nil,
                limit: 200,
                nextCursor: nil
            )
        )
        let requestedURLs = LockedRequestPaths()
        let client = makeClient { request in
            requestedURLs.append(request.url?.absoluteString ?? "")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                request.url?.query?.contains("cursor=next-page") == true
                    ? secondPage : firstPage
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        try await store.refreshManualDrafts()

        XCTAssertEqual(store.manualDrafts.map(\.id), [firstDraft.id, secondDraft.id])
        XCTAssertEqual(requestedURLs.values.count, 2)
        XCTAssertTrue(requestedURLs.values[0].contains("limit=200"))
        XCTAssertTrue(requestedURLs.values[1].contains("cursor=next-page"))
    }

    @MainActor
    func testImageProductionDraftQueuesAndPlainDraftDeleteRemovesIt() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let now = Date.now
        let serverDraft = StudyManualCardDraft(
            id: "01J0000000000000000000000Q1",
            status: "generating",
            committedCardId: nil,
            creationKind: .productionImage,
            cardType: "production",
            prompt: .object([:]),
            answer: .object([
                "expression": .string("会社"),
                "meaning": .string("company"),
            ]),
            imagePlacement: .prompt,
            imagePrompt: "A Japanese company office",
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now
        )
        let responseData = try StorageCodec.encoder.encode(serverDraft)
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            paths.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            if request.httpMethod == "POST" {
                let body = try requestBody(request)
                let payload = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                XCTAssertEqual(payload["creationKind"] as? String, "production-image")
                XCTAssertEqual(payload["cardType"] as? String, "production")
                XCTAssertEqual(payload["imagePlacement"] as? String, "prompt")
                XCTAssertEqual(
                    payload["imagePrompt"] as? String,
                    "A Japanese company office"
                )
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    responseData
                )
            }
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
        var draft = StudyCardDraft(cardType: .production)
        draft.answerExpression = "会社"
        draft.answerMeaning = "company"
        draft.imagePlacement = .prompt
        draft.imagePrompt = "A Japanese company office"

        let queued = try await store.queueManualDraft(
            creationKind: .productionImage,
            draft: draft,
            id: serverDraft.id
        )
        XCTAssertEqual(store.manualDrafts.map(\.id), [serverDraft.id])

        try await store.deleteManualDraft(queued)

        XCTAssertTrue(store.manualDrafts.isEmpty)
        XCTAssertEqual(
            paths.values,
            [
                "POST /api/study/card-drafts",
                "DELETE /api/study/card-drafts/\(serverDraft.id)",
            ]
        )
    }

    @MainActor
    func testManualDraftCreateRetainsItsClientIDAcrossALostResponseAndRelaunch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let clientDraftID = ClientIdentifier.ulid()
        let now = Date.now
        let serverDraft = StudyManualCardDraft(
            id: clientDraftID.lowercased(),
            status: "generating",
            committedCardId: nil,
            creationKind: .audioRecognition,
            cardType: "recognition",
            prompt: .object([:]),
            answer: .object(["expression": .string("犬")]),
            imagePlacement: .none,
            imagePrompt: nil,
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now
        )
        let responseData = try StorageCodec.encoder.encode(serverDraft)
        let attempts = LockedCounter()
        let requestIDs = LockedRequestPaths()
        let client = makeClient { request in
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try requestBody(request))
                    as? [String: Any]
            )
            requestIDs.append(try XCTUnwrap(payload["id"] as? String))
            let status = attempts.next() == 1 ? 500 : 200
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                status == 200
                    ? responseData
                    : Data(#"{"message":"response lost"}"#.utf8)
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        var draft = StudyCardDraft(cardType: .recognition)
        draft.isAudioLedPrompt = true
        draft.isMediaLedPrompt = true
        draft.answerExpression = "犬"

        do {
            _ = try await store.queueManualDraft(
                creationKind: .audioRecognition,
                draft: draft,
                id: clientDraftID
            )
            XCTFail("Expected the first draft request to lose its response")
        } catch let APIClientError.rejected(status, _) {
            XCTAssertEqual(status, 500)
        }

        let pendingAfterFailure = try container.mainContext.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate { $0.kind == "draftCreate" }
            )
        )
        XCTAssertEqual(pendingAfterFailure.map(\.resourceID), [clientDraftID])
        XCTAssertEqual(pendingAfterFailure.first?.attemptCount, 1)

        let relaunchedStore = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        try await relaunchedStore.retryPendingDraftCreates()

        XCTAssertEqual(requestIDs.values, [clientDraftID, clientDraftID])
        XCTAssertTrue(
            try container.mainContext.fetch(
                FetchDescriptor<PendingMutation>(
                    predicate: #Predicate { $0.kind == "draftCreate" }
                )
            ).isEmpty
        )
        XCTAssertEqual(
            relaunchedStore.manualDrafts.map(\.id),
            [clientDraftID.lowercased()]
        )
    }

    @MainActor
    func testPermanentlyRejectedManualDraftCreateIsQuarantinedFromBackgroundRetry() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let attempts = LockedCounter()
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/study/card-drafts")
            _ = attempts.next()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 422,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"message":"The image prompt is too long."}"#.utf8)
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        var draft = StudyCardDraft(cardType: .production)
        draft.answerExpression = "会社"
        draft.answerMeaning = "company"
        draft.imagePlacement = .prompt
        draft.imagePrompt = String(repeating: "a", count: 1_001)

        do {
            _ = try await store.queueManualDraft(
                creationKind: .productionImage,
                draft: draft
            )
            XCTFail("Expected the invalid draft to be rejected")
        } catch let APIClientError.rejected(status, _) {
            XCTAssertEqual(status, 422)
        }

        XCTAssertEqual(attempts.current, 1)
        XCTAssertEqual(store.quarantinedMutationCount, 1)
        let pending = try container.mainContext.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate { $0.kind == "draftCreate" }
            )
        )
        XCTAssertNotNil(pending.first?.lastError)

        try await store.retryPendingDraftCreates()

        XCTAssertEqual(attempts.current, 1)
        XCTAssertEqual(store.quarantinedMutationCount, 1)
    }

    @MainActor
    func testManualDraftCreateRetryUsesLatestEditedPayload() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let clientDraftID = ClientIdentifier.ulid()
        let now = Date.now
        let serverDraft = StudyManualCardDraft(
            id: clientDraftID.lowercased(),
            status: "generating",
            committedCardId: nil,
            creationKind: .audioRecognition,
            cardType: "recognition",
            prompt: .object([:]),
            answer: .object(["expression": .string("猫")]),
            imagePlacement: .none,
            imagePrompt: nil,
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now
        )
        let responseData = try StorageCodec.encoder.encode(serverDraft)
        let attempts = LockedCounter()
        let submittedExpressions = LockedRequestPaths()
        let client = makeClient { request in
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try requestBody(request))
                    as? [String: Any]
            )
            let answer = try XCTUnwrap(payload["answer"] as? [String: Any])
            submittedExpressions.append(try XCTUnwrap(answer["expression"] as? String))
            let status = attempts.next() == 1 ? 500 : 200
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                status == 200
                    ? responseData
                    : Data(#"{"message":"try again"}"#.utf8)
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        var draft = StudyCardDraft(cardType: .recognition)
        draft.isAudioLedPrompt = true
        draft.isMediaLedPrompt = true
        draft.answerExpression = "犬"

        do {
            _ = try await store.queueManualDraft(
                creationKind: .audioRecognition,
                draft: draft,
                id: clientDraftID
            )
            XCTFail("Expected the first draft request to fail")
        } catch let APIClientError.rejected(status, _) {
            XCTAssertEqual(status, 500)
        }

        draft.answerExpression = "猫"
        _ = try await store.queueManualDraft(
            creationKind: .audioRecognition,
            draft: draft,
            id: clientDraftID
        )

        XCTAssertEqual(submittedExpressions.values, ["犬", "猫"])
    }

    @MainActor
    func testManualDraftUpdatePreservesExistingPreviewMediaWhenOmitted() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let previewAudio: JSONValue = .object([
            "id": .string("preview-audio"),
            "url": .string("/api/study/media/preview-audio"),
        ])
        let previewImage: JSONValue = .object([
            "id": .string("preview-image"),
            "url": .string("/api/study/media/preview-image"),
        ])
        let now = Date.now
        let serverDraft = StudyManualCardDraft(
            id: "01J00000000000000000000P1",
            status: "ready",
            committedCardId: nil,
            creationKind: .audioRecognition,
            cardType: "recognition",
            prompt: .object([:]),
            answer: .object(["expression": .string("犬")]),
            imagePlacement: .answer,
            imagePrompt: nil,
            previewAudio: previewAudio,
            previewAudioRole: "prompt",
            previewImage: previewImage,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now
        )
        let responseData = try StorageCodec.encoder.encode(serverDraft)
        let client = makeClient { request in
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try requestBody(request))
                    as? [String: Any]
            )
            XCTAssertEqual(
                (payload["previewAudio"] as? [String: Any])?["id"] as? String,
                "preview-audio"
            )
            XCTAssertEqual(payload["previewAudioRole"] as? String, "prompt")
            XCTAssertEqual(
                (payload["previewImage"] as? [String: Any])?["id"] as? String,
                "preview-image"
            )
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
        var draft = StudyCardDraft(cardType: .recognition)
        draft.isAudioLedPrompt = true
        draft.isMediaLedPrompt = true
        draft.answerExpression = "犬"

        _ = try await store.updateManualDraft(serverDraft, draft: draft)
    }

    @MainActor
    func testManualDraftRefreshCoalescesAndDoesNotOverwriteANewerLocalDraft() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let now = Date.now
        let queuedDraft = StudyManualCardDraft(
            id: "01J0000000000000000000000R1",
            status: "generating",
            committedCardId: nil,
            creationKind: .audioRecognition,
            cardType: "recognition",
            prompt: .object([:]),
            answer: .object(["expression": .string("新しい下書き")]),
            imagePlacement: .none,
            imagePrompt: nil,
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now
        )
        let emptyPage = try StorageCodec.encoder.encode(
            StudyManualCardDraftListResponse(
                drafts: [],
                total: 0,
                limit: 200,
                nextCursor: nil
            )
        )
        let listGate = LockedRequestGate()
        let listRequests = LockedCounter()
        let client = makeClient { request in
            _ = listRequests.next()
            listGate.markStarted()
            listGate.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                emptyPage
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        let firstRefresh = Task { try await store.refreshManualDrafts() }
        await waitUntil { listGate.hasStarted }
        let secondRefresh = Task { try await store.refreshManualDrafts() }
        store.replaceManualDraft(queuedDraft)
        listGate.release()
        try await firstRefresh.value
        try await secondRefresh.value

        XCTAssertEqual(listRequests.current, 1)
        XCTAssertEqual(store.manualDrafts.map(\.id), [queuedDraft.id])
    }

    @MainActor
    func testManualAndBackgroundDraftCommitShareOneInFlightRequest() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000S1"
        let clientCardID = "01J0000000000000000000000S2"
        let now = Date.now
        let serverDraft = StudyManualCardDraft(
            id: draftID,
            status: "ready",
            committedCardId: nil,
            creationKind: .audioRecognition,
            cardType: "recognition",
            prompt: .object([:]),
            answer: .object(["expression": .string("一回")]),
            imagePlacement: .none,
            imagePrompt: nil,
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now
        )
        let committedCard = makeCard(
            id: clientCardID.lowercased(),
            expression: "一回"
        )
        let committedData = try StorageCodec.encoder.encode(committedCard)
        let mutation = PendingMutation(
            kind: "draftCommit",
            userID: 1,
            resourceID: draftID,
            payload: try StorageCodec.encoder.encode(
                CreateCardFromStudyManualDraftRequest(id: clientCardID)
            )
        )
        container.mainContext.insert(mutation)
        try container.mainContext.save()
        let createAttempts = LockedCounter()
        let client = makeClient { request in
            if request.url?.path.hasSuffix("/create-card") == true {
                _ = createAttempts.next()
                Thread.sleep(forTimeInterval: 0.05)
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    committedData
                )
            }
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
        var draft = StudyCardDraft(cardType: .recognition)
        draft.isAudioLedPrompt = true
        draft.isMediaLedPrompt = true
        draft.answerExpression = "一回"

        async let manual: Void = store.createCard(
            from: serverDraft,
            draft: draft,
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil
        )
        async let background: Void = store.retryPendingDraftCommits()
        _ = try await (manual, background)

        XCTAssertEqual(createAttempts.current, 1)
        XCTAssertEqual(store.libraryCards.map(\.id), [committedCard.id])
        XCTAssertFalse(store.hasPendingDraftCommit(for: draftID))
    }

    @MainActor
    func testOfflineClozeCreationQueuesTypeAwarePayload() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        var draft = StudyCardDraft(cardType: .cloze)
        draft.cueText = "毎日{{c1::勉強する}}。"
        draft.cueMeaning = "daily habit"
        draft.answerExpression = "毎日勉強する。"
        draft.answerReading = "毎日[まいにち]勉強[べんきょう]する。"
        draft.answerMeaning = "I study every day."

        try await store.createCard(draft)

        let card = try XCTUnwrap(store.libraryCards.first)
        XCTAssertEqual(card.cardType, "cloze")
        XCTAssertEqual(card.prompt["clozeText"]?.stringValue, "毎日{{c1::勉強する}}。")
        XCTAssertEqual(card.answer["restoredText"]?.stringValue, "毎日勉強する。")
        let mutation = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                .first(where: { $0.kind == "cardCreate" })
        )
        let request = try StorageCodec.decoder.decode(
            CreateStudyCardRequest.self,
            from: mutation.payload
        )
        XCTAssertEqual(request.cardType, "cloze")
        XCTAssertEqual(request.prompt, card.prompt)
        XCTAssertEqual(request.answer, card.answer)
    }

    @MainActor
    func testOfflineTextProductionCreationQueuesTypeAwarePayload() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        var draft = StudyCardDraft(cardType: .production)
        draft.cueText = "to learn"
        draft.answerExpression = "学ぶ"
        draft.answerReading = "学[まな]ぶ"
        draft.answerMeaning = "to learn"

        try await store.createCard(draft)

        let card = try XCTUnwrap(store.libraryCards.first)
        XCTAssertEqual(card.cardType, "production")
        XCTAssertEqual(card.prompt["cueText"]?.stringValue, "to learn")
        XCTAssertEqual(card.answer["expression"]?.stringValue, "学ぶ")
        let mutation = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                .first(where: { $0.kind == "cardCreate" })
        )
        let request = try StorageCodec.decoder.decode(
            CreateStudyCardRequest.self,
            from: mutation.payload
        )
        XCTAssertEqual(request.cardType, "production")
        XCTAssertEqual(request.prompt, card.prompt)
        XCTAssertEqual(request.answer, card.answer)
    }

    @MainActor
    func testRegenerateAnswerAudioPersistsSettingsAndRefreshesOfflineMedia() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000000AA",
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
            expression: "元"
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
        XCTAssertNotNil(record.locallyUpdatedAt)
        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(pending.map(\.kind), ["cardUpdate"])
        XCTAssertNotNil(pending.first?.lastError)
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
        XCTAssertEqual(updated.presentation.back.pitchAccent?.reading, "かいしゃ")
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
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
        let reviewed = card.applyingReview(.good, at: reviewedAt)
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

    @MainActor
    func testCardBecomingDueDoesNotReplaceVisibleCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let visibleCard = makeCard(
            id: "01J00000000000000000000015",
            expression: "新しい",
            queueState: "new"
        )
        let dueAt = Date.now.addingTimeInterval(60)
        let futureReview = makeCard(
            id: "01J00000000000000000000016",
            expression: "復習",
            dueAt: dueAt
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: visibleCard,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(visibleCard)
            )
        )
        let futureRecord = LocalCardRecord(
            card: futureReview,
            userID: 1,
            queueIndex: 1,
            payload: try StorageCodec.encoder.encode(futureReview)
        )
        futureRecord.isInActiveSession = false
        container.mainContext.insert(futureRecord)
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let mediaCache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        store.activateOfflineDueCards(at: dueAt)

        XCTAssertEqual(store.cards.map(\.id), [visibleCard.id, futureReview.id])
    }

    @MainActor
    func testLoadNextReviewBatchPromotesNewlyDueOfflineReserveBeforeSyncing() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let futureCard = makeCard(
            id: "01J00000000000000000000019",
            expression: "次",
            dueAt: Date.now.addingTimeInterval(60)
        )
        let record = LocalCardRecord(
            card: futureCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(futureCard)
        )
        record.isInActiveSession = false
        container.mainContext.insert(record)
        try container.mainContext.save()
        let requestedPaths = LockedRequestPaths()
        let client = makeClient { request in
            requestedPaths.append(request.url?.path ?? "")
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
        XCTAssertTrue(store.cards.isEmpty)

        let readyCard = makeCard(
            id: futureCard.id,
            expression: "次",
            dueAt: Date.now.addingTimeInterval(-1)
        )
        record.payload = try StorageCodec.encoder.encode(readyCard)
        try container.mainContext.save()

        await store.loadNextReviewBatch()

        XCTAssertEqual(store.cards.map(\.id), [readyCard.id])
        XCTAssertEqual(store.sessionProgress, 0)
        XCTAssertTrue(requestedPaths.values.isEmpty)
        XCTAssertTrue(record.isInActiveSession)
    }

    @MainActor
    func testLoadNextReviewBatchFallsBackToServerWhenOfflineReserveIsEmpty() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let serverCard = makeCard(
            id: "01J0000000000000000000001A",
            expression: "同期",
            dueAt: Date.now.addingTimeInterval(-1)
        )
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 10,
                newCardsAvailableToday: 0
            ),
            cards: [serverCard]
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(
            withJSONObject: ["data": sessionObject]
        )
        let requestedPaths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            requestedPaths.append(path)
            let data: Data
            switch path {
            case "/api/sync/feed":
                data = Data(
                    #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
                )
            case "/api/study/known-kanji":
                data = Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                )
            case "/api/study/session/start":
                data = sessionData
            case "/api/study/offline-reserve":
                data = Data(
                    #"{"cards":[],"reserveDays":5,"generatedAt":"2026-07-25T12:00:00.000Z","horizonEndsAt":"2026-07-30T12:00:00.000Z"}"#.utf8
                )
            default:
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
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

        await store.loadNextReviewBatch()

        XCTAssertEqual(store.cards.map(\.id), [serverCard.id])
        XCTAssertEqual(store.sessionProgress, 0)
        XCTAssertEqual(
            requestedPaths.values,
            [
                "/api/sync/feed",
                "/api/study/known-kanji",
                "/api/study/session/start",
                "/api/study/offline-reserve",
            ]
        )
    }

    @MainActor
    func testOfflineDueActivationDoesNotResurrectCaseCanonicalizedPendingDelete() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01j00000000000000000000018",
            expression: "削除",
            dueAt: .now
        )
        let record = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        record.isInActiveSession = false
        container.mainContext.insert(record)
        container.mainContext.insert(
            PendingMutation(
                kind: "cardDelete",
                userID: 1,
                resourceID: card.id.uppercased(),
                payload: Data()
            )
        )
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let mediaCache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        store.activateOfflineDueCards(at: .now)

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertFalse(record.isInActiveSession)
    }

    @MainActor
    func testDueActivationTimerReactivatesCardWhileStoreRemainsOpen() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let dueAt = Date.now.addingTimeInterval(1.5)
        let card = makeCard(
            id: "01J00000000000000000000017",
            expression: "時間",
            dueAt: dueAt
        )
        let record = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        record.isInActiveSession = false
        container.mainContext.insert(record)
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let mediaCache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        XCTAssertTrue(store.cards.isEmpty)
        for _ in 0..<30 where store.cards.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertEqual(store.cards.map(\.id), [card.id])
    }

    @MainActor
    func testAgainReturnsWhenDueOfflineAndLaterGoodClearsFailure() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000014",
            expression: "繰り返す"
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
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let mediaCache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )
        let firstReviewAt = Date(timeIntervalSince1970: 1_800_000_000)

        await store.recordReview(
            card: card,
            rating: .again,
            duration: nil,
            reviewedAt: firstReviewAt
        )

        let againDueAt = try XCTUnwrap(store.libraryCards.first?.state.dueAt)
        XCTAssertEqual(againDueAt, firstReviewAt.addingTimeInterval(10 * 60))
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(store.sessionCounts.failedDue, 0)
        XCTAssertEqual(store.sessionFailureCount, 1)

        store.activateOfflineDueCards(at: againDueAt.addingTimeInterval(-1))
        XCTAssertTrue(store.cards.isEmpty)

        store.activateOfflineDueCards(at: againDueAt)
        let firstRetryCard = try XCTUnwrap(store.cards.first)
        XCTAssertEqual(firstRetryCard.state.queueState, "relearning")
        XCTAssertNotNil(firstRetryCard.state.failedAt)

        await store.recordReview(
            card: firstRetryCard,
            rating: .again,
            duration: nil,
            reviewedAt: againDueAt
        )

        XCTAssertEqual(store.sessionFailureCount, 1)
        let secondRetryDueAt = try XCTUnwrap(store.libraryCards.first?.state.dueAt)
        store.activateOfflineDueCards(at: secondRetryDueAt)
        let secondRetryCard = try XCTUnwrap(store.cards.first)

        await store.recordReview(
            card: secondRetryCard,
            rating: .good,
            duration: nil,
            reviewedAt: secondRetryDueAt
        )

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(store.sessionCounts.failedDue, 0)
        XCTAssertEqual(store.sessionFailureCount, 0)

        let relaunched = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )
        XCTAssertTrue(relaunched.cards.isEmpty)
        XCTAssertEqual(relaunched.sessionCounts.failedDue, 0)
        XCTAssertEqual(relaunched.sessionFailureCount, 0)

        let goodDueAt = try XCTUnwrap(relaunched.libraryCards.first?.state.dueAt)
        XCTAssertEqual(goodDueAt, secondRetryDueAt.addingTimeInterval(24 * 60 * 60))
        relaunched.activateOfflineDueCards(at: goodDueAt)
        XCTAssertEqual(relaunched.cards.map(\.id), [card.id])
        XCTAssertEqual(relaunched.cards.first?.state.queueState, "review")
        XCTAssertNil(relaunched.cards.first?.state.failedAt)
    }

    @MainActor
    func testFirstTimeOfflineFailureSurvivesRelaunchAndStaleServerRefresh() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "01J00000000000000000000011", expression: "再学習")
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let mediaCache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        await store.recordReview(card: card, rating: .again, duration: nil)

        XCTAssertEqual(store.sessionCounts.failedDue, 0)
        XCTAssertTrue(store.cards.isEmpty)

        let relaunched = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )
        XCTAssertEqual(relaunched.sessionCounts.failedDue, 0)
        XCTAssertTrue(relaunched.cards.isEmpty)

        let staleSession = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 20,
                newCardsAvailableToday: 0,
                failedCount: 0
            ),
            cards: [card]
        )
        let object = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(staleSession)
        )
        let data = try JSONSerialization.data(withJSONObject: ["data": object])
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/study/session/start")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }

        try await relaunched.refreshSession()

        XCTAssertTrue(relaunched.cards.isEmpty)
        XCTAssertEqual(relaunched.sessionCounts.failedDue, 0)
    }

    @MainActor
    func testCorruptedPendingReviewDoesNotBlockSessionRefresh() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let reviewedCard = makeCard(
            id: "01J00000000000000000000012",
            expression: "破損"
        )
        let availableCard = makeCard(
            id: "01J00000000000000000000013",
            expression: "利用可能"
        )
        container.mainContext.insert(
            PendingMutation(
                kind: "review",
                userID: 1,
                resourceID: reviewedCard.id,
                payload: Data("not-json".utf8)
            )
        )
        try container.mainContext.save()
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 2,
                newCount: 0,
                reviewCount: 2,
                newCardsPerDay: 20,
                newCardsAvailableToday: 0
            ),
            cards: [reviewedCard, availableCard]
        )
        let object = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let data = try JSONSerialization.data(withJSONObject: ["data": object])
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/session/start")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        try await store.refreshSession()

        XCTAssertEqual(store.cards.map(\.id), [availableCard.id])
        XCTAssertEqual(store.overview?.dueCount, 2)
    }

    @MainActor
    func testLessonRefreshUsesDedicatedEndpointAndStartsFrozenBatchProgress() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let lessonCards = [
            makeCard(
                id: "01J00000000000000000000014",
                expression: "営業する",
                queueState: "new"
            ),
            makeCard(
                id: "01J00000000000000000000015",
                expression: "講義",
                queueState: "new"
            ),
        ]
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 3,
                newCount: 8,
                reviewCount: 3,
                newCardsPerDay: 20,
                newCardsAvailableToday: 8,
                lessonBatchSize: 2
            ),
            cards: lessonCards
        )
        let object = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let data = try JSONSerialization.data(withJSONObject: ["data": object])
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path == "/api/card-review-events/batch" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"data":[]}"#.utf8)
                )
            }
            XCTAssertTrue(
                ["/api/study/lessons/start", "/api/study/session/start"].contains(path)
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        store.beginLessonSessionPresentation()
        try await store.refreshLessons()

        XCTAssertEqual(store.cards.map(\.id), lessonCards.map(\.id))
        XCTAssertEqual(store.sessionKind, "lessons")
        XCTAssertEqual(store.sessionProgress, 0)
        XCTAssertEqual(store.sessionInitialCardCount, 2)

        store.retryLessonCard(lessonCards[0])

        XCTAssertEqual(store.cards.map(\.id), [lessonCards[1].id, lessonCards[0].id])
        XCTAssertEqual(store.sessionProgress, 0)
        XCTAssertEqual(store.cards.map(\.state.queueState), ["new", "new"])

        let refreshedWhilePresented = try await store.refreshSessionPreservingActiveLessons()

        XCTAssertFalse(refreshedWhilePresented)
        XCTAssertEqual(paths.values, ["/api/study/lessons/start"])
        XCTAssertEqual(store.sessionKind, "lessons")
        XCTAssertEqual(store.cards.map(\.id), [lessonCards[1].id, lessonCards[0].id])

        let eventID = await store.recordReview(
            card: lessonCards[1],
            rating: .good,
            duration: nil
        )

        XCTAssertNotNil(eventID)
        XCTAssertEqual(store.cards.map(\.id), [lessonCards[0].id])
        XCTAssertEqual(store.sessionProgress, 0.5)
        XCTAssertEqual(
            paths.values,
            ["/api/study/lessons/start", "/api/card-review-events/batch"]
        )

        store.endLessonSessionPresentation()
        XCTAssertTrue(store.cards.isEmpty)
        let refreshedAfterLeaving = try await store.refreshSessionPreservingActiveLessons()

        XCTAssertTrue(refreshedAfterLeaving)
        XCTAssertEqual(store.sessionKind, "reviews")
        XCTAssertEqual(
            paths.values,
            [
                "/api/study/lessons/start",
                "/api/card-review-events/batch",
                "/api/study/session/start",
            ]
        )

        store.beginLessonSessionPresentation()
        store.deactivate()
        store.activate(userID: 1)
        let refreshedAfterReactivation = try await store.refreshSessionPreservingActiveLessons()

        XCTAssertTrue(refreshedAfterReactivation)
        XCTAssertEqual(paths.values.last, "/api/study/session/start")
    }

    @MainActor
    func testLessonRefreshCapsOversizedServerResponseToConfiguredBatch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let lessonCards = (0..<50).map { index in
            makeCard(
                id: String(format: "01J%023d", index),
                expression: "Lesson card \(index)",
                queueState: "new"
            )
        }
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 50,
                reviewCount: 0,
                newCardsPerDay: 50,
                newCardsAvailableToday: 50,
                lessonBatchSize: 5
            ),
            cards: lessonCards
        )
        let object = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let data = try JSONSerialization.data(withJSONObject: ["data": object])
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/lessons/start")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
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

        try await store.refreshLessons()

        XCTAssertEqual(store.cards.map(\.id), lessonCards.prefix(5).map(\.id))
        XCTAssertEqual(store.sessionInitialCardCount, 5)
        XCTAssertEqual(store.overview?.lessonBatchSize, 5)
    }

    @MainActor
    func testReviewingFailedCardOptimisticallyUpdatesSessionCounts() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let failedCard = StudyCard(
            id: "98f42a62-8303-410e-ad4d-5a69c55911bb",
            syncId: "01J00000000000000000000010",
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string("失敗")]),
            answer: .object(["meaning": .string("failure")]),
            state: .init(
                dueAt: .now,
                introducedAt: .now,
                failedAt: .now,
                queueState: "relearning",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: .now,
            updatedAt: .now
        )
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 0,
                reviewCount: 0,
                newCardsPerDay: 20,
                newCardsAvailableToday: 0,
                failedCount: 3,
                failedDueCount: 3
            ),
            cards: [failedCard]
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let expectedSyncID = failedCard.syncId
        let client = makeClient { request in
            if request.url?.path == "/api/study/session/start" {
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
            XCTAssertEqual(request.url?.path, "/api/card-review-events/batch")
            let body = try requestBody(request)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
            XCTAssertEqual(events.first?["card_id"] as? String, expectedSyncID)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"data":[]}"#.utf8)
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        try await store.refreshSession()
        XCTAssertEqual(store.sessionCounts.failedDue, 3)

        await store.recordReview(card: failedCard, rating: .good, duration: nil)

        XCTAssertEqual(
            store.sessionCounts,
            StudySessionCounts(failedDue: 2, reviewRemaining: 0, newRemaining: 0)
        )
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
    }

    @MainActor
    func testRefreshDeDuplicatesRepeatedServerCardIDs() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "01J00000000000000000000009", expression: "重複")
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 0,
                newCardsAvailableToday: 0
            ),
            cards: [card, card]
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                sessionData
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        try await store.refreshSession()

        XCTAssertEqual(store.cards.map(\.id), [card.id])
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<LocalCardRecord>()),
            1
        )
    }

    @MainActor
    func testRefreshOnlyMarksCardsPreparedWhenEveryDeclaredMediaFileExists() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let missingMediaCard = makeCard(
            id: "01J00000000000000000000006",
            expression: "未取得",
            mediaURL: "/api/study/media/missing"
        )
        let downloadedMediaCard = makeCard(
            id: "01J00000000000000000000007",
            expression: "取得済み",
            mediaURL: "/api/study/media/available"
        )
        let textOnlyCard = makeCard(
            id: "01J00000000000000000000008",
            expression: "文字のみ"
        )
        let staleRecord = LocalCardRecord(
            card: missingMediaCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(missingMediaCard)
        )
        staleRecord.mediaPreparedAt = .now
        container.mainContext.insert(staleRecord)
        try container.mainContext.save()

        let session = StudySession(
            overview: StudyOverview(
                dueCount: 3,
                newCount: 0,
                reviewCount: 3,
                newCardsPerDay: 0,
                newCardsAvailableToday: 0
            ),
            cards: [missingMediaCard, downloadedMediaCard, textOnlyCard]
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let client = makeClient { request in
            let path = request.url?.path
            if path == "/api/study/session/start" {
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
            let available = path == "/api/study/media/available"
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: available ? 200 : 404,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                available ? Data("audio".utf8) : Data()
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        try await store.refreshSession()

        XCTAssertEqual(store.preparedCardCount, 2)
        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertNil(records.first(where: { $0.id == missingMediaCard.id })?.mediaPreparedAt)
        XCTAssertNotNil(
            records.first(where: { $0.id == downloadedMediaCard.id })?.mediaPreparedAt
        )
        XCTAssertNotNil(records.first(where: { $0.id == textOnlyCard.id })?.mediaPreparedAt)
    }

    @MainActor
    func testDeletingOfflineCreatedCardDoesNotResurrectIt() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        let mediaCache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        try await store.createCard(expression: "犬", reading: "いぬ", meaning: "dog")
        let card = try XCTUnwrap(store.cards.first)
        let cardData = try StorageCodec.encoder.encode(card)

        MockURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
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
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                cardData
            )
        }

        try await store.deleteCard(card)

        let localCards = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(localCards.isEmpty)
        XCTAssertTrue(pending.filter { $0.kind.hasPrefix("card") }.isEmpty)
    }

    @MainActor
    func testRefreshDoesNotResurrectCardWithQuarantinedDelete() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "01J00000000000000000000003", expression: "削除")
        let delete = PendingMutation(kind: "cardDelete", userID: 1, resourceID: card.id, payload: Data())
        delete.lastError = "HTTP 409: Delete conflict"
        container.mainContext.insert(delete)
        try container.mainContext.save()

        let session = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 10,
                newCardsAvailableToday: 0
            ),
            cards: [card]
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let envelopeData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                envelopeData
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        try await store.refreshSession()

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(store.libraryCards.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
    }

    @MainActor
    func testCardUpdatePreservesReadingAndServerManagedPayloadFields() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = StudyCard(
            id: "01J00000000000000000000004",
            noteId: nil,
            cardType: "recognition",
            prompt: .object([
                "cueText": .string("古い文"),
                "cueReading": .string("古[ふる]い文[ぶん]"),
                "cueAudio": .object(["url": .string("/api/media/prompt")]),
            ]),
            answer: .object([
                "expression": .string("古い文"),
                "meaning": .string("old sentence"),
                "answerAudio": .object(["url": .string("/api/media/answer")]),
                "notes": .string("Keep this note"),
            ]),
            state: .init(
                dueAt: nil,
                introducedAt: nil,
                failedAt: nil,
                queueState: "review",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "generated",
            createdAt: .now,
            updatedAt: .now
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
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        try await store.updateCard(
            card,
            prompt: "新しい文",
            reading: "新[あたら]しい文[ぶん]",
            answer: "new sentence"
        )

        let updated = try XCTUnwrap(store.libraryCards.first)
        XCTAssertEqual(updated.prompt["cueText"]?.stringValue, "新しい文")
        XCTAssertEqual(updated.prompt["cueReading"]?.stringValue, "新[あたら]しい文[ぶん]")
        XCTAssertEqual(updated.prompt["cueAudio"], card.prompt["cueAudio"])
        XCTAssertEqual(updated.answer["meaning"]?.stringValue, "new sentence")
        XCTAssertEqual(updated.answer["answerAudio"], card.answer["answerAudio"])
        XCTAssertEqual(updated.answer["notes"]?.stringValue, "Keep this note")

        let mutation = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                .first(where: { $0.kind == "cardUpdate" })
        )
        let request = try StorageCodec.decoder.decode(
            UpdateStudyCardRequest.self,
            from: mutation.payload
        )
        XCTAssertEqual(request.prompt["cueAudio"], card.prompt["cueAudio"])
        XCTAssertEqual(request.answer["answerAudio"], card.answer["answerAudio"])
    }

    @MainActor
    func testRefreshKeepsLocallyDirtyCardInActiveQueue() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        let mediaCache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )
        try await store.createCard(expression: "猫", reading: "ねこ", meaning: "cat")
        let card = try XCTUnwrap(store.cards.first)
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 1,
                reviewCount: 0,
                newCardsPerDay: 10,
                newCardsAvailableToday: 1
            ),
            cards: [card]
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let envelopeData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                envelopeData
            )
        }

        try await store.refreshSession()

        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(try XCTUnwrap(records.first).isInActiveSession)
        XCTAssertNotNil(records.first?.locallyUpdatedAt)
    }

    @MainActor
    func testRejectedReviewDoesNotBlockNewerReview() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let rejectedCard = makeCard(id: "01J00000000000000000000001", expression: "犬")
        let acceptedCard = makeCard(id: "01J00000000000000000000002", expression: "猫")
        let requestCounter = LockedCounter()
        let client = makeClient { request in
            let status = requestCounter.next() <= 2 ? 422 : 204
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                status == 422 ? Data(#"{"message":"Invalid review"}"#.utf8) : Data()
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        await store.recordReview(card: rejectedCard, rating: .good, duration: nil)
        await store.recordReview(card: acceptedCard, rating: .good, duration: nil)

        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
            .filter { $0.kind == "review" }
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.resourceID, rejectedCard.id)
        XCTAssertEqual(pending.first?.attemptCount, 1)
        XCTAssertNotNil(pending.first?.lastError)
    }

    @MainActor
    func testOfflineReviewBacklogUploadsInOneBatch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
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
        let cards = (0..<4).map {
            makeCard(
                id: "01J000000000000000000000\(String(format: "%02d", $0))",
                expression: "card-\($0)"
            )
        }

        for card in cards.prefix(3) {
            await store.recordReview(card: card, rating: .good, duration: nil)
        }

        let uploadedBatchSizes = LockedRequestPaths()
        MockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(
                with: try requestBody(request)
            ) as? [String: Any]
            let events = try XCTUnwrap(body?["events"] as? [[String: Any]])
            uploadedBatchSizes.append(String(events.count))
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data()
            )
        }

        await store.recordReview(card: cards[3], rating: .good, duration: nil)

        XCTAssertEqual(uploadedBatchSizes.values, ["4"])
        XCTAssertTrue(
            try container.mainContext.fetch(
                FetchDescriptor<PendingMutation>(
                    predicate: #Predicate { $0.kind == "review" }
                )
            ).isEmpty
        )
    }

    @MainActor
    func testNewCardCreateFlushesBeforeItsReview() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let offlineClient = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(initialUserID: 1,
            api: offlineClient,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: offlineClient, context: container.mainContext)
        )

        try await store.createCard(expression: "同期", reading: "どうき", meaning: "sync")
        let card = try XCTUnwrap(store.cards.first)
        await store.recordReview(card: card, rating: .good, duration: nil)
        let locallyReviewedCard = try XCTUnwrap(
            store.libraryCards.first { $0.id == card.id }
        )
        let serverCreatedAt = card.createdAt.addingTimeInterval(-60)
        let serverUpdatedAt = card.updatedAt.addingTimeInterval(1)
        let serverCard = StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: "server-note-id",
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer,
            state: card.state,
            answerAudioSource: "generated",
            createdAt: serverCreatedAt,
            updatedAt: serverUpdatedAt
        )
        let serverCardData = try StorageCodec.encoder.encode(serverCard)
        let decodedServerCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: serverCardData
        )
        let decodedReviewedCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: StorageCodec.encoder.encode(locallyReviewedCard)
        )
        XCTAssertEqual(
            Set(
                try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                    .map(\.kind)
            ),
            ["cardCreate", "review"]
        )

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
        let paths = LockedRequestPaths()
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            let status = path == "/api/study/session/start" ? 200 : 201
            let data: Data
            switch path {
            case "/api/study/cards":
                data = serverCardData
            case "/api/study/session/start":
                data = sessionData
            default:
                data = Data(#"{"data":[]}"#.utf8)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }

        await store.synchronize()

        XCTAssertEqual(
            paths.values,
            [
                "/api/study/cards",
                "/api/card-review-events/batch",
                "/api/sync/feed",
                "/api/study/known-kanji",
                "/api/study/session/start",
                "/api/study/offline-reserve",
            ]
        )
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let storedCard = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertNil(record.locallyUpdatedAt)
        XCTAssertEqual(record.serverUpdatedAt, decodedServerCard.updatedAt)
        XCTAssertEqual(storedCard.noteId, "server-note-id")
        XCTAssertEqual(storedCard.answerAudioSource, "generated")
        XCTAssertEqual(storedCard.createdAt, decodedServerCard.createdAt)
        XCTAssertEqual(storedCard.state, decodedReviewedCard.state)
        XCTAssertEqual(storedCard.updatedAt, decodedReviewedCard.updatedAt)
    }

    @MainActor
    func testSynchronizationPullsCanonicalInboundCardAndAdvancesCheckpoint() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        container.mainContext.insert(
            LocalSyncState(userID: 1, cardCheckpoint: 1_234)
        )
        try container.mainContext.save()
        let serverCard = makeCard(
            id: "01J00000000000000000000AA",
            expression: "受信"
        )
        let secondServerCard = makeCard(
            id: "01J00000000000000000000AB",
            expression: "一括"
        )
        let serverCardID = serverCard.id
        let secondServerCardID = secondServerCard.id
        let serverCardObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(serverCard)
        )
        let secondServerCardObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(secondServerCard)
        )
        let serverCardBatchData = try JSONSerialization.data(
            withJSONObject: ["cards": [serverCardObject, secondServerCardObject]]
        )
        let emptySession = StudySession(
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
            with: StorageCodec.encoder.encode(emptySession)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            let data: Data
            switch path {
            case "/api/sync/feed":
                let queryItems = URLComponents(
                    url: try XCTUnwrap(request.url),
                    resolvingAgainstBaseURL: false
                )?.queryItems
                XCTAssertEqual(
                    queryItems?.first(where: { $0.name == "after_checkpoint" })?.value,
                    "1234"
                )
                XCTAssertEqual(
                    queryItems?.first(where: { $0.name == "per_page" })?.value,
                    "50"
                )
                data = Data(
                    """
                    {"data":[
                    {"checkpoint":1235,"resource_id":"\(serverCardID)","operation":"update"},
                    {"checkpoint":1236,"resource_id":"\(secondServerCardID)","operation":"create"}],
                    "meta":{"next_checkpoint":1236,"has_more":false}}
                    """.utf8
                )
            case "/api/study/cards/batch":
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: requestBody(request)) as? [String: [String]]
                )
                XCTAssertEqual(body, ["ids": [serverCardID, secondServerCardID]])
                data = serverCardBatchData
            case "/api/study/known-kanji":
                data = Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                )
            case "/api/study/session/start":
                data = sessionData
            case "/api/study/offline-reserve":
                data = Data(
                    #"{"cards":[],"reserveDays":5,"generatedAt":"2026-07-25T12:00:00.000Z","horizonEndsAt":"2026-07-30T12:00:00.000Z"}"#.utf8
                )
            default:
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
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

        await store.synchronize()

        XCTAssertEqual(
            paths.values,
            [
                "/api/sync/feed",
                "/api/study/cards/batch",
                "/api/study/known-kanji",
                "/api/study/session/start",
                "/api/study/offline-reserve",
            ]
        )
        XCTAssertEqual(Set(store.libraryCards.map(\.id)), Set([serverCardID, secondServerCardID]))
        XCTAssertEqual(
            try XCTUnwrap(
                container.mainContext.fetch(FetchDescriptor<LocalSyncState>()).first
            ).cardCheckpoint,
            1_236
        )
        XCTAssertEqual(store.syncStatus, .idle)

        await store.synchronizeIfNeeded(maxAge: .seconds(60))

        XCTAssertEqual(
            paths.values,
            [
                "/api/sync/feed",
                "/api/study/cards/batch",
                "/api/study/known-kanji",
                "/api/study/session/start",
                "/api/study/offline-reserve",
            ],
            "A recent successful sync should suppress redundant Study-page refreshes."
        )
    }

    @MainActor
    func testOfflineReadinessCountsPreparedReserveCardsOutsideActiveSession() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000002B",
            expression: "予備"
        )
        let record = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        record.isInActiveSession = false
        record.mediaPreparedAt = .now
        container.mainContext.insert(record)
        try container.mainContext.save()
        let client = makeClient { _ in
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
        defer { store.deactivate() }

        XCTAssertEqual(store.preparedCardCount, 1)
    }

    @MainActor
    func testMissingCardBatchEndpointFailsOnceWithoutIndividualFallbackRequests() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let serverCardID = "01J0000000000000000000002C"
        let emptySession = StudySession(
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
            with: StorageCodec.encoder.encode(emptySession)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            let statusCode: Int
            let data: Data
            switch path {
            case "/api/sync/feed":
                statusCode = 200
                data = Data(
                    """
                    {"data":[
                    {"checkpoint":1,"resource_id":"\(serverCardID)","operation":"update"}],
                    "meta":{"next_checkpoint":1,"has_more":false}}
                    """.utf8
                )
            case "/api/study/cards/batch":
                statusCode = 404
                data = Data(#"{"message":"Not Found"}"#.utf8)
            case "/api/study/known-kanji":
                statusCode = 200
                data = Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                )
            case "/api/study/session/start":
                statusCode = 200
                data = sessionData
            case "/api/study/offline-reserve":
                statusCode = 200
                data = Data(
                    #"{"cards":[],"reserveDays":5,"generatedAt":"2026-07-25T12:00:00.000Z","horizonEndsAt":"2026-07-30T12:00:00.000Z"}"#.utf8
                )
            default:
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
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
        defer { store.deactivate() }

        await store.synchronize()

        XCTAssertEqual(
            paths.values.count(where: { $0 == "/api/study/cards/batch" }),
            1
        )
        XCTAssertFalse(
            paths.values.contains(where: {
                $0.hasPrefix("/api/study/cards/") && $0 != "/api/study/cards/batch"
            })
        )
        XCTAssertEqual(
            try XCTUnwrap(
                container.mainContext.fetch(FetchDescriptor<LocalSyncState>()).first
            ).cardCheckpoint,
            0
        )
        guard case .failed = store.syncStatus else {
            return XCTFail("The unavailable batch endpoint should fail this sync attempt.")
        }
    }

    @MainActor
    func testPartialCardBatchResponseResolvesWholePageWithoutPermanentRetryWedge() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000002D",
            expression: "保持"
        )
        let cardID = card.id
        let omittedCardIDs = [
            cardID,
            "01J0000000000000000000002E",
            "01J0000000000000000000002F",
            "01J0000000000000000000002G",
        ]
        let record = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        record.mediaPreparedAt = .now
        container.mainContext.insert(record)
        try container.mainContext.save()
        let emptySession = StudySession(
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
            with: StorageCodec.encoder.encode(emptySession)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let individualRequestCount = LockedCounter()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            let data: Data
            switch path {
            case "/api/sync/feed":
                let entries = omittedCardIDs.enumerated().map { index, resourceID in
                    """
                    {"checkpoint":\(index + 1),"resource_id":"\(resourceID)","operation":"update"}
                    """
                }.joined(separator: ",")
                data = Data(
                    """
                    {"data":[\(entries)],
                    "meta":{"next_checkpoint":4,"has_more":false}}
                    """.utf8
                )
            case "/api/study/cards/batch":
                data = Data(#"{"cards":[]}"#.utf8)
            case let path where path.hasPrefix("/api/study/cards/"):
                let attempt = individualRequestCount.next()
                let statusCode = attempt == 1 ? 500 : 404
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: statusCode,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"message":"Unavailable"}"#.utf8)
                )
            case "/api/study/known-kanji":
                data = Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                )
            case "/api/study/session/start":
                data = sessionData
            case "/api/study/offline-reserve":
                data = Data(
                    #"{"cards":[],"reserveDays":5,"generatedAt":"2026-07-25T12:00:00.000Z","horizonEndsAt":"2026-07-30T12:00:00.000Z"}"#.utf8
                )
            default:
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
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
        defer { store.deactivate() }

        await store.synchronize()

        XCTAssertEqual(store.libraryCards.map(\.id), [cardID])
        XCTAssertEqual(store.preparedCardCount, 0)
        XCTAssertEqual(
            try XCTUnwrap(
                container.mainContext.fetch(FetchDescriptor<LocalSyncState>()).first
            ).cardCheckpoint,
            0
        )
        guard case .failed = store.syncStatus else {
            return XCTFail("A transient resolution failure should leave the sync page retryable.")
        }

        await store.synchronize()

        XCTAssertEqual(individualRequestCount.current, 5)
        XCTAssertTrue(store.libraryCards.isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(
                container.mainContext.fetch(FetchDescriptor<LocalSyncState>()).first
            ).cardCheckpoint,
            4
        )
        XCTAssertEqual(store.syncStatus, .idle)
    }

    @MainActor
    func testStudySettingsRefreshAndUpdateUseCompatibilityPayload() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/settings")
            if request.httpMethod == "PATCH" {
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Int]
                )
                XCTAssertEqual(body, [
                    "lessonBatchSize": 5,
                    "newCardsPerDay": 24,
                ])
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"newCardsPerDay":24}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"newCardsPerDay":12}"#.utf8)
            )
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

        await store.refreshStudySettings()
        XCTAssertEqual(store.studySettings?.newCardsPerDay, 12)
        XCTAssertEqual(store.studySettings?.lessonBatchSize, 5)

        let saved = await store.updateNewCardsPerDay(24)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.studySettings?.newCardsPerDay, 24)
        XCTAssertNil(store.studySettingsErrorMessage)
    }

    @MainActor
    func testStaleStudySettingsResponseCannotPopulateNewAccount() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let gate = LockedRequestGate()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/settings")
            gate.markStarted()
            gate.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"newCardsPerDay":12}"#.utf8)
            )
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

        let refresh = Task { await store.refreshStudySettings() }
        for _ in 0..<100 where !gate.hasStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(gate.hasStarted)

        store.activate(userID: 2)
        gate.release()
        await refresh.value

        XCTAssertNil(store.studySettings)
        XCTAssertNil(store.studySettingsErrorMessage)
    }

    @MainActor
    func testStaleNewCardQueueResponseCannotPopulateNewAccount() async throws {
        let cardID = "01J00000000000000000000001"
        let container = try Persistence.makeContainer(inMemory: true)
        let gate = LockedRequestGate()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/new-queue")
            gate.markStarted()
            gate.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    """
                    {
                      "items": [{
                        "id": "\(cardID)",
                        "noteId": "\(cardID)",
                        "cardType": "recognition",
                        "displayText": "犬",
                        "meaning": "dog",
                        "queuePosition": 1,
                        "createdAt": "2026-07-25T12:00:00.000Z",
                        "updatedAt": "2026-07-25T12:00:00.000Z"
                      }],
                      "total": 1,
                      "limit": 100,
                      "nextCursor": null
                    }
                    """.utf8
                )
            )
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

        let refresh = Task { try await store.refreshNewCardQueue() }
        for _ in 0..<100 where !gate.hasStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(gate.hasStarted)

        store.activate(userID: 2)
        gate.release()
        try await refresh.value

        XCTAssertTrue(store.newCardQueue.isEmpty)
        XCTAssertEqual(store.newCardQueueTotal, 0)
    }

    @MainActor
    func testStaleCheckpointResponseCannotReplaceNewAccountsCards() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let userOneCard = makeCard(
            id: "01J00000000000000000000A1",
            expression: "前の利用者"
        )
        let userTwoCard = makeCard(
            id: "01J00000000000000000000A2",
            expression: "現在の利用者"
        )
        container.mainContext.insert(LocalCardRecord(
            card: userOneCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(userOneCard)
        ))
        container.mainContext.insert(LocalCardRecord(
            card: userTwoCard,
            userID: 2,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(userTwoCard)
        ))
        try container.mainContext.save()
        let gate = LockedRequestGate()
        let client = makeClient { request in
            guard request.url?.path == "/api/sync/feed" else {
                throw URLError(.badServerResponse)
            }
            gate.markStarted()
            gate.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 409,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"message":"Checkpoint expired"}"#.utf8)
            )
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

        let synchronization = Task { await store.synchronize() }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)
        store.activate(userID: 2)
        gate.release()
        await synchronization.value

        XCTAssertEqual(store.cards.map(\.id), [userTwoCard.id])
        XCTAssertEqual(store.libraryCards.map(\.id), [userTwoCard.id])
        XCTAssertEqual(store.syncStatus, .idle)
    }

    @MainActor
    func testAccountSwitchCannotAdvanceCheckpointPastSkippedCardChanges() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let serverCard = makeCard(
            id: "01J00000000000000000000C1",
            expression: "未適用"
        )
        let serverCardID = serverCard.id
        let serverCardData = try StorageCodec.encoder.encode(serverCard)
        let serverCardObject = try JSONSerialization.jsonObject(with: serverCardData)
        let serverCardBatchData = try JSONSerialization.data(
            withJSONObject: ["cards": [serverCardObject]]
        )
        let gate = LockedRequestGate()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/sync/feed":
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(
                        """
                        {"data":[{"checkpoint":9,"resource_id":"\(serverCardID)","operation":"update"}],
                        "meta":{"next_checkpoint":9,"has_more":false}}
                        """.utf8
                    )
                )
            case "/api/study/cards/batch":
                gate.markStarted()
                gate.waitForRelease()
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    serverCardBatchData
                )
            default:
                throw URLError(.badServerResponse)
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

        let synchronization = Task { await store.synchronize() }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)
        store.activate(userID: 2)
        gate.release()
        await synchronization.value

        let states = try container.mainContext.fetch(FetchDescriptor<LocalSyncState>())
        XCTAssertEqual(states.first(where: { $0.userID == 1 })?.cardCheckpoint, 0)
        XCTAssertFalse(try container.mainContext.fetch(
            FetchDescriptor<LocalCardRecord>()
        ).contains(where: { $0.userID == 1 && $0.id == serverCardID }))
        XCTAssertEqual(store.syncStatus, .idle)
    }

    @MainActor
    func testRejectedCardCreateSurfacesItsDependentReview() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let offlineClient = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(initialUserID: 1,
            api: offlineClient,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: offlineClient, context: container.mainContext)
        )

        try await store.createCard(expression: "拒否", reading: "きょひ", meaning: "reject")
        let card = try XCTUnwrap(store.cards.first)
        await store.recordReview(card: card, rating: .good, duration: nil)
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
        MockURLProtocol.handler = { request in
            let path = request.url?.path
            let status: Int
            let data: Data
            switch path {
            case "/api/study/cards":
                status = 422
                data = Data(#"{"message":"Invalid card"}"#.utf8)
            case "/api/card-review-events/batch":
                status = 404
                data = Data(#"{"message":"Card not found"}"#.utf8)
            default:
                status = 200
                data = sessionData
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }

        await store.synchronize()

        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(Set(pending.map(\.kind)), ["cardCreate", "review"])
        XCTAssertTrue(pending.allSatisfy { $0.lastError != nil })
        XCTAssertEqual(store.quarantinedMutationCount, 2)
    }

    @MainActor
    func testQuarantinedReviewDoesNotBlockCardSyncOrSessionRefresh() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        let rejectedReviewCard = makeCard(
            id: "01J00000000000000000000005",
            expression: "失敗"
        )
        await store.recordReview(card: rejectedReviewCard, rating: .good, duration: nil)
        try await store.createCard(expression: "同期", reading: "どうき", meaning: "sync")
        let createdCard = try XCTUnwrap(store.libraryCards.last)
        let createdCardData = try StorageCodec.encoder.encode(createdCard)
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 1,
                reviewCount: 1,
                newCardsPerDay: 10,
                newCardsAvailableToday: 1
            ),
            cards: [rejectedReviewCard, createdCard]
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])

        MockURLProtocol.handler = { request in
            let path = request.url?.path
            if path == "/api/card-review-events/batch" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 422,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"message":"Invalid review"}"#.utf8)
                )
            }
            if path == "/api/study/cards" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    createdCardData
                )
            }
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

        await store.synchronize()

        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(pending.filter { $0.kind == "review" }.count, 1)
        XCTAssertTrue(pending.filter { $0.kind.hasPrefix("card") }.isEmpty)
        XCTAssertEqual(store.overview?.newCount, 1)
        XCTAssertEqual(Set(store.cards.map(\.id)), [rejectedReviewCard.id, createdCard.id])
        XCTAssertNotNil(store.lastSyncAt)
    }

    @MainActor
    func testRejectedCardMutationDoesNotBlockNewerCardMutation() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        try await store.createCard(expression: "犬", reading: "いぬ", meaning: "dog")
        try await store.createCard(expression: "猫", reading: "ねこ", meaning: "cat")
        let offlinePending = try container.mainContext.fetch(
            FetchDescriptor<PendingMutation>(sortBy: [SortDescriptor(\.createdAt)])
        ).filter { $0.kind.hasPrefix("card") }
        let rejectedAttemptsBeforeSync = try XCTUnwrap(offlinePending.first).attemptCount
        let acceptedCard = try XCTUnwrap(store.cards.last)
        let acceptedCardData = try StorageCodec.encoder.encode(acceptedCard)
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
        let cardRequestCounter = LockedCounter()
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/study/session/start" {
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
            let status = cardRequestCounter.next() == 1 ? 422 : 201
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                status == 422
                    ? Data(#"{"message":"Invalid card"}"#.utf8)
                    : acceptedCardData
            )
        }

        await store.synchronize()

        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
            .filter { $0.kind.hasPrefix("card") }
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.attemptCount, rejectedAttemptsBeforeSync + 1)
        XCTAssertNotNil(pending.first?.lastError)
    }

    @MainActor
    func testOfflineReviewedCardStaysOutOfQueueAfterRelaunch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000018",
            expression: "鳥"
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
        let client = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        let mediaCache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        await store.recordReview(card: card, rating: .good, duration: .milliseconds(750))
        let relaunchedStore = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(relaunchedStore.cards.isEmpty)
        XCTAssertEqual(store.libraryCards.map(\.id), [card.id])
        XCTAssertEqual(relaunchedStore.libraryCards.map(\.id), [card.id])
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        XCTAssertFalse(record.isInActiveSession)
        let reviewMutation = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                .first(where: { $0.kind == "review" })
        )
        let storedReview = try JSONSerialization.jsonObject(
            with: reviewMutation.payload
        ) as? [String: Any]
        let event = try XCTUnwrap(storedReview?["event"])
        let eventData = try JSONSerialization.data(withJSONObject: event)
        let review = try StorageCodec.decoder.decode(
            ReviewBatchRequest.Event.self,
            from: eventData
        )
        XCTAssertEqual(review.durationMilliseconds, 750)
    }

    @MainActor
    func testUndoReviewRestoresFrozenSessionProgress() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000001T",
            expression: "進捗"
        )
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 20,
                newCardsAvailableToday: 0,
                failedCount: 2
            ),
            cards: [card]
        )
        let object = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": object])
        let client = makeClient { request in
            if request.url?.path == "/api/study/session/start" {
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
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        try await store.refreshSession()

        XCTAssertEqual(store.sessionCounts.failedDue, 2)
        XCTAssertEqual(store.sessionFailureCount, 0)

        let recordedEventID = await store.recordReview(
            card: card,
            rating: .again,
            duration: nil
        )
        let eventID = try XCTUnwrap(recordedEventID)
        XCTAssertEqual(store.sessionProgress, 1)
        XCTAssertEqual(store.sessionFailureCount, 1)

        try await store.refreshSession()
        XCTAssertEqual(store.sessionFailureCount, 1)

        try await store.undoReview(eventID: eventID, cardBefore: card)

        XCTAssertEqual(store.sessionProgress, 0)
        XCTAssertEqual(store.sessionFailureCount, 0)
        XCTAssertEqual(store.cards.map(\.id), [card.id])

        await store.recordReview(card: card, rating: .again, duration: nil)
        XCTAssertEqual(store.sessionFailureCount, 1)
        let secondCard = makeCard(
            id: "01J0000000000000000000001V",
            expression: "失敗"
        )
        await store.recordReview(card: secondCard, rating: .again, duration: nil)
        XCTAssertEqual(store.sessionFailureCount, 2)
        store.beginSessionFailureTracking()
        XCTAssertEqual(store.sessionFailureCount, 0)
    }

    @MainActor
    func testMasteryAnimationRemainsVisibleAfterTheReviewedCardAdvances() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000001U",
            expression: "復習",
            scheduler: .object([
                "due": .string("2026-04-12T00:00:00.000Z"),
                "stability": .number(54.1885),
                "difficulty": .number(9.317),
                "elapsed_days": .number(59),
                "scheduled_days": .number(59),
                "learning_steps": .number(0),
                "reps": .number(12),
                "lapses": .number(1),
                "state": .number(2),
                "last_review": .string("2026-02-12T13:01:42.000Z"),
            ])
        )
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 20,
                newCardsAvailableToday: 0
            ),
            cards: [card]
        )
        let object = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": object])
        let client = makeClient { request in
            if request.url?.path == "/api/study/session/start" {
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
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        try await store.refreshSession()

        let recordedEventID = await store.recordReview(
            card: card,
            rating: .good,
            duration: nil
        )
        let eventID = try XCTUnwrap(recordedEventID)

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(
            store.masteryAnimation?.fromLevel,
            StudyMasteryLevel.master.rawValue
        )
        XCTAssertEqual(
            store.masteryAnimation?.toLevel,
            StudyMasteryLevel.enlightened.rawValue
        )
        XCTAssertEqual(store.masteryAnimation?.card.id, card.id)
        XCTAssertEqual(store.masteryAnimation?.passed, true)

        try await store.undoReview(eventID: eventID, cardBefore: card)

        XCTAssertNil(store.masteryAnimation)

        let sameStageEventID = await store.recordReview(
            card: card,
            rating: .hard,
            duration: nil
        )

        XCTAssertEqual(store.masteryAnimation?.passed, true)
        XCTAssertEqual(
            store.masteryAnimation?.fromLevel,
            StudyMasteryLevel.master.rawValue
        )
        XCTAssertEqual(
            store.masteryAnimation?.toLevel,
            StudyMasteryLevel.master.rawValue
        )

        try await store.undoReview(
            eventID: try XCTUnwrap(sameStageEventID),
            cardBefore: card
        )

        _ = await store.recordReview(
            card: card,
            rating: .again,
            duration: nil
        )

        XCTAssertEqual(store.masteryAnimation?.passed, false)
        XCTAssertEqual(
            store.masteryAnimation?.fromLevel,
            StudyMasteryLevel.master.rawValue
        )
        XCTAssertEqual(
            store.masteryAnimation?.toLevel,
            StudyMasteryLevel.apprentice.rawValue
        )
    }

    @MainActor
    func testUndoReviewRemovesPendingOfflineEventAndRestoresCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000001U",
            expression: "戻す"
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
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        let recordedEventID = await store.recordReview(
            card: card,
            rating: .good,
            duration: .milliseconds(500)
        )
        let eventID = try XCTUnwrap(recordedEventID)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(requestCount.current, 1)

        try await store.undoReview(eventID: eventID, cardBefore: card)

        XCTAssertEqual(store.cards.map(\.id), [card.id])
        XCTAssertEqual(requestCount.current, 1)
        XCTAssertTrue(
            try container.mainContext.fetch(
                FetchDescriptor<PendingMutation>(
                    predicate: #Predicate { $0.kind == "review" }
                )
            ).isEmpty
        )
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        XCTAssertTrue(record.isInActiveSession)
        XCTAssertEqual(try persistedCard(in: container).state, card.state)
    }

    @MainActor
    func testUndoSyncedReviewUsesCanonicalUndoResponse() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000001V",
            expression: "取り消す"
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
        let overview = StudyOverview(
            dueCount: 1,
            newCount: 0,
            reviewCount: 1,
            newCardsPerDay: 10,
            newCardsAvailableToday: 0
        )
        let paths = LockedRequestPaths()
        let undoEventIDs = LockedRequestPaths()
        let cardJSON = try XCTUnwrap(
            String(
                data: StorageCodec.encoder.encode(card),
                encoding: .utf8
            )
        )
        let overviewJSON = try XCTUnwrap(
            String(
                data: StorageCodec.encoder.encode(overview),
                encoding: .utf8
            )
        )
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path == "/api/card-review-events/batch" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data()
                )
            }

            let body = try JSONSerialization.jsonObject(
                with: try requestBody(request)
            ) as? [String: Any]
            let eventID = try XCTUnwrap(body?["reviewLogId"] as? String)
            undoEventIDs.append(eventID)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    """
                    {
                      "reviewLogId": "\(eventID)",
                      "card": \(cardJSON),
                      "overview": \(overviewJSON)
                    }
                    """.utf8
                )
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        let recordedEventID = await store.recordReview(
            card: card,
            rating: .easy,
            duration: .seconds(1)
        )
        let eventID = try XCTUnwrap(recordedEventID)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(
                FetchDescriptor<PendingMutation>(
                    predicate: #Predicate { $0.kind == "review" }
                )
            ).isEmpty
        )

        try await store.undoReview(eventID: eventID, cardBefore: card)

        XCTAssertEqual(
            paths.values,
            ["/api/card-review-events/batch", "/api/study/reviews/undo"]
        )
        XCTAssertEqual(undoEventIDs.values, [eventID.lowercased()])
        XCTAssertEqual(store.cards.map(\.id), [card.id])
        XCTAssertEqual(store.sessionCounts.reviewRemaining, 1)
    }

    @MainActor
    func testUndoWaitsForInFlightReviewUploadBeforeCallingServerUndo() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000001X",
            expression: "競合を避ける"
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

        let overview = StudyOverview(
            dueCount: 1,
            newCount: 0,
            reviewCount: 1,
            newCardsPerDay: 10,
            newCardsAvailableToday: 0
        )
        let cardJSON = try XCTUnwrap(
            String(
                data: StorageCodec.encoder.encode(card),
                encoding: .utf8
            )
        )
        let overviewJSON = try XCTUnwrap(
            String(
                data: StorageCodec.encoder.encode(overview),
                encoding: .utf8
            )
        )
        let gate = LockedRequestGate()
        let paths = LockedRequestPaths()
        let uploadedEventIDs = LockedRequestPaths()
        let undoEventIDs = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path == "/api/card-review-events/batch" {
                let body = try JSONSerialization.jsonObject(
                    with: try requestBody(request)
                ) as? [String: Any]
                let events = try XCTUnwrap(body?["events"] as? [[String: Any]])
                let eventID = try XCTUnwrap(events.first?["id"] as? String)
                uploadedEventIDs.append(eventID)
                gate.markStarted()
                gate.waitForRelease()
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data()
                )
            }

            let body = try JSONSerialization.jsonObject(
                with: try requestBody(request)
            ) as? [String: Any]
            let eventID = try XCTUnwrap(body?["reviewLogId"] as? String)
            undoEventIDs.append(eventID)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    """
                    {
                      "reviewLogId": "\(eventID)",
                      "card": \(cardJSON),
                      "overview": \(overviewJSON)
                    }
                    """.utf8
                )
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        let reviewTask = Task {
            await store.recordReview(
                card: card,
                rating: .good,
                duration: .milliseconds(500)
            )
        }
        await waitUntil { gate.hasStarted }
        let eventID = try XCTUnwrap(uploadedEventIDs.values.first)
        let undoTask = Task {
            try await store.undoReview(eventID: eventID, cardBefore: card)
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(paths.values, ["/api/card-review-events/batch"])

        gate.release()
        let recordedEventID = await reviewTask.value
        try await undoTask.value

        XCTAssertEqual(recordedEventID, eventID)
        XCTAssertEqual(
            paths.values,
            ["/api/card-review-events/batch", "/api/study/reviews/undo"]
        )
        XCTAssertEqual(undoEventIDs.values, [eventID.lowercased()])
        XCTAssertEqual(store.cards.map(\.id), [card.id])
        XCTAssertTrue(
            try container.mainContext.fetch(
                FetchDescriptor<PendingMutation>(
                    predicate: #Predicate { $0.kind == "review" }
                )
            ).isEmpty
        )
    }

    @MainActor
    func testPendingDeleteDuringServerUndoDoesNotApplyRestoredOverview() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000002A",
            expression: "削除競合"
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
        let responseOverview = StudyOverview(
            dueCount: 1,
            newCount: 0,
            reviewCount: 1,
            newCardsPerDay: 10,
            newCardsAvailableToday: 0
        )
        let cardJSON = try XCTUnwrap(
            String(
                data: StorageCodec.encoder.encode(card),
                encoding: .utf8
            )
        )
        let overviewJSON = try XCTUnwrap(
            String(
                data: StorageCodec.encoder.encode(responseOverview),
                encoding: .utf8
            )
        )
        let gate = LockedRequestGate()
        let client = makeClient { request in
            guard request.url?.path == "/api/study/reviews/undo" else {
                throw URLError(.notConnectedToInternet)
            }
            gate.markStarted()
            gate.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    """
                    {
                      "reviewLogId": "01j0000000000000000000002b",
                      "card": \(cardJSON),
                      "overview": \(overviewJSON)
                    }
                    """.utf8
                )
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        let undoTask = Task {
            try await store.undoReview(
                eventID: "01J0000000000000000000002B",
                cardBefore: card
            )
        }
        await waitUntil { gate.hasStarted }
        container.mainContext.insert(
            PendingMutation(
                kind: "cardDelete",
                userID: 1,
                resourceID: card.id,
                payload: Data()
            )
        )
        let localRecords = try container.mainContext.fetch(
            FetchDescriptor<LocalCardRecord>()
        )
        for record in localRecords {
            container.mainContext.delete(record)
        }
        try container.mainContext.save()
        gate.release()

        do {
            try await undoTask.value
            XCTFail("Expected the pending delete to reject restoration.")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "This card was deleted and cannot be restored."
            )
        }

        XCTAssertNil(store.overview)
        XCTAssertTrue(
            try container.mainContext.fetch(
                FetchDescriptor<LocalCardRecord>()
            ).isEmpty
        )
    }

    @MainActor
    func testUndoDoesNotResurrectCardWithPendingDelete() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000001Y",
            expression: "削除済み"
        )
        container.mainContext.insert(
            PendingMutation(
                kind: "cardDelete",
                userID: 1,
                resourceID: card.id.lowercased(),
                payload: Data()
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

        do {
            try await store.undoReview(
                eventID: "01J0000000000000000000001Z",
                cardBefore: card
            )
            XCTFail("Expected undo to reject a pending card deletion.")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "This card was deleted and cannot be restored."
            )
        }

        XCTAssertEqual(requestCount.current, 0)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(store.libraryCards.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(
                FetchDescriptor<LocalCardRecord>()
            ).isEmpty
        )
    }

    @MainActor
    func testUndoReviewReusesCanonicalRecordAndPreservesPendingEdit() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let originalID = "01J0000000000000000000001W"
        let canonicalID = originalID.lowercased()
        let locallyEditedCard = makeCard(
            id: originalID,
            expression: "Local pending edit",
            queueState: "review"
        )
        let dirtyAt = Date(timeIntervalSince1970: 1_000)
        let record = LocalCardRecord(
            card: locallyEditedCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(locallyEditedCard)
        )
        record.id = canonicalID
        record.locallyUpdatedAt = dirtyAt
        container.mainContext.insert(record)
        try container.mainContext.save()

        let serverCard = makeCard(
            id: originalID,
            expression: "Stale server expression",
            queueState: "learning",
            dueAt: Date(timeIntervalSince1970: 2_000)
        )
        let overview = StudyOverview(
            dueCount: 1,
            newCount: 0,
            reviewCount: 1,
            newCardsPerDay: 10,
            newCardsAvailableToday: 0
        )
        let cardJSON = try XCTUnwrap(
            String(
                data: StorageCodec.encoder.encode(serverCard),
                encoding: .utf8
            )
        )
        let overviewJSON = try XCTUnwrap(
            String(
                data: StorageCodec.encoder.encode(overview),
                encoding: .utf8
            )
        )
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/reviews/undo")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    """
                    {
                      "reviewLogId": "review-event-id",
                      "card": \(cardJSON),
                      "overview": \(overviewJSON)
                    }
                    """.utf8
                )
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        try await store.undoReview(
            eventID: "review-event-id",
            cardBefore: locallyEditedCard
        )

        let records = try container.mainContext.fetch(
            FetchDescriptor<LocalCardRecord>()
        )
        XCTAssertEqual(records.count, 1)
        let restoredRecord = try XCTUnwrap(records.first)
        XCTAssertEqual(restoredRecord.id, canonicalID)
        XCTAssertEqual(restoredRecord.locallyUpdatedAt, dirtyAt)
        let restoredCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: restoredRecord.payload
        )
        XCTAssertEqual(restoredCard.id, canonicalID)
        XCTAssertEqual(restoredCard.promptText, "Local pending edit")
        XCTAssertEqual(restoredCard.state, serverCard.state)
        XCTAssertEqual(store.cards.first, restoredCard)
    }

    @MainActor
    private func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    private func makeDelayedPitchClient(
        responseData: Data,
        gate: LockedRequestGate
    ) -> APIClient {
        DelayedPitchURLProtocol.responseData = responseData
        DelayedPitchURLProtocol.gate = gate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedPitchURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    private func makeDelayedAnswerAudioClient(
        responseData: Data,
        gate: LockedRequestGate
    ) -> APIClient {
        DelayedAnswerAudioURLProtocol.responseData = responseData
        DelayedAnswerAudioURLProtocol.gate = gate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedAnswerAudioURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    private func makeDelayedAnswerAudioDownloadClient(
        responseData: Data,
        gate: LockedRequestGate
    ) -> APIClient {
        DelayedAnswerAudioDownloadURLProtocol.responseData = responseData
        DelayedAnswerAudioDownloadURLProtocol.gate = gate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedAnswerAudioDownloadURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    private func makeCard(
        id: String,
        expression: String,
        mediaURL: String? = nil,
        queueState: String = "review",
        dueAt: Date? = nil,
        scheduler: JSONValue? = nil
    ) -> StudyCard {
        var prompt: [String: JSONValue] = ["cueText": .string(expression)]
        if let mediaURL {
            prompt["cueAudio"] = .object(["url": .string(mediaURL)])
        }
        return StudyCard(
            id: id,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(prompt),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: dueAt,
                introducedAt: nil,
                failedAt: nil,
                queueState: queueState,
                scheduler: scheduler,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: .now,
            updatedAt: .now
        )
    }

    @MainActor
    private func cardWithResolvedPitchAccent(_ card: StudyCard) -> StudyCard {
        StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer.replacingObjectValues([
                "pitchAccent": .object([
                    "status": .string("resolved"),
                    "expression": .string("会社"),
                    "reading": .string("かいしゃ"),
                    "morae": .array([.string("か"), .string("い"), .string("しゃ")]),
                    "pattern": .array([.number(0), .number(1), .number(1)]),
                    "patternName": .string("平板"),
                ]),
            ]),
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: .now
        )
    }

    @MainActor
    private func persistedCard(
        in container: ModelContainer
    ) throws -> StudyCard {
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        return try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool
    ) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

final class LockedRequestPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }
}

final class LockedRequestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    var hasStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    func markStarted() {
        condition.lock()
        started = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForRelease() {
        condition.lock()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

final class DelayedPitchURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var gate: LockedRequestGate?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard request.url?.path.hasSuffix("/pitch-accent") == true else {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let responseData = Self.responseData
        let gate = Self.gate
        gate?.markStarted()
        DispatchQueue.global().async { [self] in
            gate?.waitForRelease()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class DelayedAnswerAudioURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var gate: LockedRequestGate?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard request.url?.path.hasSuffix("/regenerate-answer-audio") == true else {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("regenerated-audio".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let responseData = Self.responseData
        let gate = Self.gate
        gate?.markStarted()
        DispatchQueue.global().async { [self] in
            gate?.waitForRelease()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class DelayedAnswerAudioDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var gate: LockedRequestGate?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if request.url?.path.hasSuffix("/regenerate-answer-audio") == true {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.responseData)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let gate = Self.gate
        gate?.markStarted()
        DispatchQueue.global().async { [self] in
            gate?.waitForRelease()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("regenerated-audio".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
