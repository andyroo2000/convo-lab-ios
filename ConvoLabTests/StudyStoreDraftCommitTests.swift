import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
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
        XCTAssertEqual(store.allCards.map(\.id), [card.id])
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
        XCTAssertEqual(store.allCards.map(\.id), [committedCard.id])
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
}
