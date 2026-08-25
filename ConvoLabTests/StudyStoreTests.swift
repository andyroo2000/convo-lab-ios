import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
private final class TestStudyDueActivationScheduler: StudyDueActivationScheduling {
    private(set) var now: Date
    private(set) var deadline: Date?
    private(set) var scheduleCount = 0
    private(set) var cancelCount = 0
    private var action: (@MainActor @Sendable () -> Void)?

    init(now: Date) {
        self.now = now
    }

    func schedule(
        at deadline: Date,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        scheduleCount += 1
        self.deadline = deadline
        self.action = action
    }

    func cancel() {
        cancelCount += 1
        deadline = nil
        action = nil
    }

    @discardableResult
    func fire() -> Bool {
        guard let deadline, let action else { return false }
        now = deadline
        self.deadline = nil
        self.action = nil
        action()
        return true
    }
}

final class StudyStoreTests: XCTestCase {
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
    func testStudyStorePublishesManualDraftOutboxRefresh() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let serverDraft = makeManualDraft(
            id: "01J00000000000000000000O1",
            expression: "観察"
        )
        let responseData = try StorageCodec.encoder.encode(
            StudyManualCardDraftListResponse(
                drafts: [serverDraft],
                total: 1,
                limit: 200,
                nextCursor: nil
            )
        )
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/card-drafts")
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
        let changed = expectation(description: "Manual drafts observation changed")
        withObservationTracking {
            _ = store.manualDrafts
        } onChange: {
            changed.fulfill()
        }

        try await store.refreshManualDrafts()

        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(store.manualDrafts.map(\.id), [serverDraft.id])
    }

    @MainActor
    func testStaleManualDraftPatchCannotPopulateReactivatedAccount() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let oldDraft = makeManualDraft(
            id: "01J00000000000000000000O2",
            expression: "前の利用者"
        )
        let newDraft = makeManualDraft(
            id: "01J00000000000000000000O3",
            expression: "現在の利用者"
        )
        let oldDraftID = oldDraft.id
        let responseData = try StorageCodec.encoder.encode(oldDraft)
        let gate = LockedRequestGate()
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/api/study/card-drafts/\(oldDraftID)")
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
        var edited = StudyCardDraft(cardType: .recognition)
        edited.cueText = "更新中"
        edited.answerMeaning = "updating"

        let update = Task {
            try await store.updateManualDraft(oldDraft, draft: edited)
        }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)
        store.activate(userID: 2)
        store.activate(userID: 1)
        store.replaceManualDraft(newDraft)
        gate.release()

        do {
            _ = try await update.value
            XCTFail("Expected stale draft update cancellation")
        } catch is CancellationError {
            // The response belongs to the previous account.
        }
        XCTAssertEqual(store.manualDrafts.map(\.id), [newDraft.id])
    }

    @MainActor
    func testStaleManualDraftCommitRetryCannotPopulateReactivatedAccount() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J00000000000000000000O4"
        let clientCardID = "01J00000000000000000000O5"
        let committedCard = makeCard(
            id: clientCardID.lowercased(),
            expression: "前の利用者"
        )
        let responseData = try StorageCodec.encoder.encode(committedCard)
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
        let gate = LockedRequestGate()
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.url?.path,
                "/api/study/card-drafts/\(draftID)/create-card"
            )
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

        let retry = Task {
            try await store.retryPendingDraftCommits()
        }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)
        store.activate(userID: 2)
        store.activate(userID: 1)
        gate.release()

        do {
            try await retry.value
            XCTFail("Expected stale draft commit cancellation")
        } catch is CancellationError {
            // The committed card belongs to the previous account activation.
        }
        XCTAssertTrue(store.libraryCards.isEmpty)
        XCTAssertTrue(store.allCards.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
        XCTAssertTrue(store.hasPendingDraftCommit(for: draftID))
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
    func testActivationRestoresLastOverviewWithoutNetwork() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let overview = StudyOverview(
            dueCount: 7,
            newCount: 5,
            reviewCount: 120,
            totalCards: 4103,
            newCardsPerDay: 10,
            newCardsAvailableToday: 5,
            lessonBatchSize: 5,
            reviewTimeBudgetMinutes: 90
        )
        container.mainContext.insert(
            LocalStudyOverviewSnapshot(
                userID: 1,
                payload: try StorageCodec.encoder.encode(overview)
            )
        )
        try container.mainContext.save()
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

        XCTAssertEqual(store.overview?.dueCount, 7)
        XCTAssertEqual(store.overview?.newCount, 5)
        XCTAssertEqual(store.overview?.totalCards, 4103)
        XCTAssertEqual(store.studySettings?.lessonBatchSize, 5)
        store.deactivate()
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
    func testSuccessfulSynchronizationDoesNotClearBlockedStorageWriteWarning() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
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
        let sessionData = try JSONSerialization.data(
            withJSONObject: ["data": sessionObject]
        )
        let client = makeClient { request in
            let data: Data
            switch request.url?.path {
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
                    url: try XCTUnwrap(request.url),
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
            ),
            storageMode: .temporary
        )

        let eventID = await store.recordReview(
            card: makeCard(id: "blocked-review", expression: "保存不可"),
            rating: .good,
            duration: nil
        )
        await store.synchronize()

        XCTAssertNil(eventID)
        XCTAssertEqual(store.syncStatus, .idle)
        XCTAssertEqual(
            store.storageWriteErrorMessage,
            StorageWriteUnavailableError(domain: .study).localizedDescription
        )
    }

    @MainActor
    func testOfflineDueActivationDoesNotResurrectAliasedPendingDelete() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "local-card-id",
            syncId: "server-card-id",
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
                resourceID: "SERVER-CARD-ID",
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
    func testOfflineDueActivationDoesNotDuplicateAnActiveCardAlias() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let activeCard = makeCard(
            id: "local-card-id",
            syncId: "server-card-id",
            expression: "学習中",
            dueAt: .now
        )
        let activeRecord = LocalCardRecord(
            card: activeCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(activeCard)
        )
        activeRecord.isInActiveSession = true
        let aliasedCard = makeCard(
            id: "SERVER-CARD-ID",
            expression: "重複",
            dueAt: .now
        )
        let aliasedRecord = LocalCardRecord(
            card: aliasedCard,
            userID: 1,
            queueIndex: 1,
            payload: try StorageCodec.encoder.encode(aliasedCard)
        )
        aliasedRecord.isInActiveSession = false
        container.mainContext.insert(activeRecord)
        container.mainContext.insert(aliasedRecord)
        try container.mainContext.save()
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

        store.activateOfflineDueCards(at: .now)

        XCTAssertEqual(store.cards.map(\.id), ["local-card-id"])
        XCTAssertFalse(aliasedRecord.isInActiveSession)
    }

    @MainActor
    func testDueActivationTimerReactivatesCardWhileStoreRemainsOpen() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dueAt = now.addingTimeInterval(90)
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
        let scheduler = TestStudyDueActivationScheduler(now: now)
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache,
            dueActivationScheduler: scheduler
        )

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(scheduler.deadline, dueAt)
        XCTAssertTrue(scheduler.fire())

        XCTAssertEqual(store.cards.map(\.id), [card.id])
        XCTAssertNil(scheduler.deadline)
        store.deactivate()
        await Task.yield()
    }

    @MainActor
    func testDueActivationReplacesScheduleAndDeactivateCancelsIt() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let firstDueAt = now.addingTimeInterval(60)
        let secondDueAt = now.addingTimeInterval(120)
        for (id, dueAt) in [("first", firstDueAt), ("second", secondDueAt)] {
            let card = makeCard(id: id, expression: id, dueAt: dueAt)
            let record = LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
            record.isInActiveSession = false
            container.mainContext.insert(record)
        }
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let scheduler = TestStudyDueActivationScheduler(now: now)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            ),
            dueActivationScheduler: scheduler
        )

        XCTAssertEqual(scheduler.deadline, firstDueAt)
        XCTAssertTrue(scheduler.fire())
        XCTAssertEqual(store.cards.map(\.id), ["first"])
        XCTAssertEqual(scheduler.deadline, secondDueAt)
        XCTAssertEqual(scheduler.scheduleCount, 2)

        let cancelCount = scheduler.cancelCount
        store.deactivate()

        XCTAssertNil(scheduler.deadline)
        XCTAssertGreaterThan(scheduler.cancelCount, cancelCount)
        XCTAssertFalse(scheduler.fire())
        XCTAssertTrue(store.cards.isEmpty)
        await Task.yield()
    }

    @MainActor
    func testLessonPresentationSuspendsAndRestoresDueActivationSchedule() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let dueAt = now.addingTimeInterval(60)
        let card = makeCard(id: "lesson-transition", expression: "授業", dueAt: dueAt)
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
        let scheduler = TestStudyDueActivationScheduler(now: now)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            ),
            dueActivationScheduler: scheduler
        )

        XCTAssertEqual(scheduler.deadline, dueAt)
        store.beginLessonSessionPresentation()
        XCTAssertNil(scheduler.deadline)
        XCTAssertFalse(scheduler.fire())

        store.endLessonSessionPresentation()
        XCTAssertEqual(scheduler.deadline, dueAt)
        XCTAssertTrue(scheduler.fire())
        XCTAssertEqual(store.cards.map(\.id), [card.id])
        store.deactivate()
        await Task.yield()
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
    func testOlderReviewSessionResponseCannotOverwriteNewerRefresh() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let olderCard = makeCard(id: "older-session-card", expression: "古いセッション")
        let newerCard = makeCard(id: "newer-session-card", expression: "新しいセッション")
        let olderData = try sessionResponseData(cards: [olderCard])
        let newerData = try sessionResponseData(cards: [newerCard])
        OverlappingStudySessionURLProtocol.configure(
            firstReview: olderData,
            secondReview: newerData,
            lesson: newerData
        )
        let client = makeClient(protocolClass: OverlappingStudySessionURLProtocol.self)
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

        let olderRefresh = Task { try await store.refreshSession() }
        await waitUntil { OverlappingStudySessionURLProtocol.hasPendingFirstReview }
        XCTAssertTrue(OverlappingStudySessionURLProtocol.hasPendingFirstReview)
        try await store.refreshSession()
        XCTAssertEqual(store.cards.map(\.id), [newerCard.id])
        OverlappingStudySessionURLProtocol.releaseFirstReview()
        _ = try await olderRefresh.value

        XCTAssertEqual(store.cards.map(\.id), [newerCard.id])
        XCTAssertEqual(store.libraryCards.map(\.id), [newerCard.id])
    }

    @MainActor
    func testReviewResponseStartedBeforeLessonCannotReplacePresentedLesson() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let reviewCard = makeCard(id: "stale-review-card", expression: "古い復習")
        let lessonCard = makeCard(
            id: "current-lesson-card",
            expression: "現在のレッスン",
            queueState: "new"
        )
        let reviewData = try sessionResponseData(cards: [reviewCard])
        let lessonData = try sessionResponseData(cards: [lessonCard], lessonBatchSize: 3)
        OverlappingStudySessionURLProtocol.configure(
            firstReview: reviewData,
            secondReview: reviewData,
            lesson: lessonData
        )
        let client = makeClient(protocolClass: OverlappingStudySessionURLProtocol.self)
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

        let reviewRefresh = Task { try await store.refreshSession() }
        await waitUntil { OverlappingStudySessionURLProtocol.hasPendingFirstReview }
        XCTAssertTrue(OverlappingStudySessionURLProtocol.hasPendingFirstReview)
        store.beginLessonSessionPresentation()
        try await store.refreshLessons()
        XCTAssertEqual(store.cards.map(\.id), [lessonCard.id])
        OverlappingStudySessionURLProtocol.releaseFirstReview()
        _ = try await reviewRefresh.value

        XCTAssertEqual(store.sessionKind, "lessons")
        XCTAssertEqual(store.cards.map(\.id), [lessonCard.id])
        XCTAssertEqual(store.libraryCards.map(\.id), [lessonCard.id])
    }

    @MainActor
    func testRapidLessonOpenAndCloseReportsDiscardedSessionLoads() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let existingCard = makeCard(id: "existing-card", expression: "既存")
        container.mainContext.insert(
            LocalCardRecord(
                card: existingCard,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(existingCard)
            )
        )
        try container.mainContext.save()
        let reviewData = try sessionResponseData(
            cards: [makeCard(id: "discarded-review", expression: "破棄する復習")]
        )
        let lessonData = try sessionResponseData(
            cards: [makeCard(id: "discarded-lesson", expression: "破棄するレッスン")],
            lessonBatchSize: 3
        )
        OverlappingStudySessionURLProtocol.configure(
            firstReview: reviewData,
            secondReview: reviewData,
            lesson: lessonData,
            holdLesson: true
        )
        let client = makeClient(protocolClass: OverlappingStudySessionURLProtocol.self)
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

        let reviewRefresh = Task {
            try await store.refreshSessionPreservingActiveLessons()
        }
        await waitUntil { OverlappingStudySessionURLProtocol.hasPendingFirstReview }
        store.beginLessonSessionPresentation()
        XCTAssertTrue(store.cards.isEmpty)
        let lessonRefresh = Task { try await store.refreshLessons() }
        await waitUntil { OverlappingStudySessionURLProtocol.hasPendingLesson }
        XCTAssertTrue(OverlappingStudySessionURLProtocol.hasPendingLesson)
        store.endLessonSessionPresentation()
        OverlappingStudySessionURLProtocol.releaseFirstReview()
        OverlappingStudySessionURLProtocol.releaseLesson()

        let reviewApplied = try await reviewRefresh.value
        let lessonApplied = try await lessonRefresh.value
        XCTAssertFalse(reviewApplied)
        XCTAssertFalse(lessonApplied)
        XCTAssertEqual(store.cards.map(\.id), [existingCard.id])
        XCTAssertEqual(store.libraryCards.map(\.id), [existingCard.id])
    }

    @MainActor
    func testLeavingSuccessfulLessonRestoresPersistedReviewQueue() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let reviewCard = makeCard(id: "persisted-review-card", expression: "復習")
        let lessonCard = makeCard(
            id: "presented-lesson-card",
            expression: "新しい項目",
            queueState: "new"
        )
        container.mainContext.insert(LocalCardRecord(
            card: reviewCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(reviewCard)
        ))
        try container.mainContext.save()
        let lessonData = try sessionResponseData(cards: [lessonCard], lessonBatchSize: 3)
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/lessons/start":
                return Self.response(data: lessonData)
            case "/api/study/reviews/batch":
                throw URLError(.notConnectedToInternet)
            default:
                throw URLError(.badURL)
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

        XCTAssertEqual(store.cards.map(\.id), [reviewCard.id])
        store.beginLessonSessionPresentation()
        XCTAssertTrue(store.cards.isEmpty)

        try await store.refreshLessons()

        XCTAssertEqual(store.cards.map(\.id), [lessonCard.id])
        XCTAssertEqual(store.sessionKind, "lessons")
        let recordedEventID = await store.recordReview(
            card: lessonCard,
            rating: .good,
            duration: nil
        )
        let eventID = try XCTUnwrap(recordedEventID)
        XCTAssertTrue(store.cards.isEmpty)
        try await store.undoReview(eventID: eventID, cardBefore: lessonCard)
        XCTAssertEqual(store.cards.map(\.id), [lessonCard.id])
        store.endLessonSessionPresentation()

        XCTAssertEqual(store.cards.map(\.id), [reviewCard.id])
        XCTAssertEqual(store.sessionKind, "reviews")
        let activeRecords = try container.mainContext.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.userID == 1 && $0.isInActiveSession }
            )
        )
        XCTAssertEqual(activeRecords.map(\.id), [reviewCard.id])
    }

    @MainActor
    func testServerUndoStartedInLessonCannotEnterReviewsAfterLessonExit() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let reviewCard = makeCard(id: "persisted-review-before-undo", expression: "復習")
        let lessonCard = makeCard(
            id: "lesson-with-delayed-undo",
            expression: "新しい項目",
            queueState: "new"
        )
        container.mainContext.insert(LocalCardRecord(
            card: reviewCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(reviewCard)
        ))
        try container.mainContext.save()
        let lessonData = try sessionResponseData(cards: [lessonCard])
        let lessonJSON = try XCTUnwrap(
            String(data: StorageCodec.encoder.encode(lessonCard), encoding: .utf8)
        )
        let overview = StudyOverview(
            dueCount: 0,
            newCount: 1,
            reviewCount: 0,
            newCardsPerDay: 10,
            newCardsAvailableToday: 1
        )
        let overviewJSON = try XCTUnwrap(
            String(data: StorageCodec.encoder.encode(overview), encoding: .utf8)
        )
        let undoGate = LockedRequestGate()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/lessons/start":
                return Self.response(data: lessonData)
            case "/api/card-review-events/batch":
                return Self.response(statusCode: 201, data: Data())
            case "/api/study/reviews/undo":
                undoGate.markStarted()
                undoGate.waitForRelease()
                return Self.response(data: Data(
                    """
                    {
                      "reviewLogId": "delayed-lesson-undo",
                      "card": \(lessonJSON),
                      "overview": \(overviewJSON)
                    }
                    """.utf8
                ))
            default:
                throw URLError(.badURL)
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
        store.beginLessonSessionPresentation()
        try await store.refreshLessons()
        let recordedEventID = await store.recordReview(
            card: lessonCard,
            rating: .again,
            duration: nil
        )
        let eventID = try XCTUnwrap(recordedEventID)
        XCTAssertEqual(store.sessionFailureCount, 1)

        let undoTask = Task {
            try await store.undoReview(eventID: eventID, cardBefore: lessonCard)
        }
        await waitUntil { undoGate.hasStarted }
        store.endLessonSessionPresentation()
        XCTAssertEqual(store.cards.map(\.id), [reviewCard.id])

        undoGate.release()
        try await undoTask.value

        XCTAssertEqual(store.cards.map(\.id), [reviewCard.id])
        XCTAssertEqual(store.sessionFailureCount, 1)
        let activeRecords = try container.mainContext.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.userID == 1 && $0.isInActiveSession }
            )
        )
        XCTAssertEqual(activeRecords.map(\.id), [reviewCard.id])
    }

    @MainActor
    func testServerUndoFromOldLessonCannotEnterNewLessonBatch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let oldLesson = makeCard(
            id: "old-lesson-with-delayed-undo",
            expression: "前の項目",
            queueState: "new"
        )
        let newLesson = makeCard(
            id: "new-lesson-batch",
            expression: "次の項目",
            queueState: "new"
        )
        let oldLessonData = try sessionResponseData(cards: [oldLesson])
        let newLessonData = try sessionResponseData(cards: [newLesson])
        let oldLessonJSON = try XCTUnwrap(
            String(data: StorageCodec.encoder.encode(oldLesson), encoding: .utf8)
        )
        let overview = StudyOverview(
            dueCount: 0,
            newCount: 1,
            reviewCount: 0,
            newCardsPerDay: 10,
            newCardsAvailableToday: 1
        )
        let overviewJSON = try XCTUnwrap(
            String(data: StorageCodec.encoder.encode(overview), encoding: .utf8)
        )
        let lessonRequests = LockedCounter()
        let deferredUndo = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            switch request.url?.path {
            case "/api/study/lessons/start":
                completion(.success(Self.response(
                    data: lessonRequests.next() == 1 ? oldLessonData : newLessonData
                )))
            case "/api/card-review-events/batch":
                completion(.success(Self.response(statusCode: 201, data: Data())))
            case "/api/study/reviews/undo":
                deferredUndo.hold(completion)
            default:
                completion(.failure(URLError(.badURL)))
            }
        }
        let undoResponse = Self.response(data: Data(
            """
            {
              "reviewLogId": "old-lesson-delayed-undo",
              "card": \(oldLessonJSON),
              "overview": \(overviewJSON)
            }
            """.utf8
        ))
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
        store.beginLessonSessionPresentation()
        try await store.refreshLessons()
        let recordedEventID = await store.recordReview(
            card: oldLesson,
            rating: .good,
            duration: nil
        )
        let eventID = try XCTUnwrap(recordedEventID)
        let undoTask = Task {
            try await store.undoReview(eventID: eventID, cardBefore: oldLesson)
        }
        await waitUntil { deferredUndo.hasPendingResponse }

        try await store.refreshLessons()
        XCTAssertEqual(store.cards.map(\.id), [newLesson.id])
        deferredUndo.succeed(with: undoResponse)
        try await undoTask.value

        XCTAssertEqual(store.cards.map(\.id), [newLesson.id])
        let activeRecords = try container.mainContext.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.userID == 1 && $0.isInActiveSession }
            )
        )
        XCTAssertTrue(activeRecords.isEmpty)
    }

    @MainActor
    func testCheckpointResetWhileServerUndoIsInFlightCannotRestoreActiveQueue() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let resetCard = makeCard(
            id: "review-discarded-by-checkpoint-reset",
            expression: "再構築前の復習"
        )
        let record = LocalCardRecord(
            card: resetCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(resetCard)
        )
        record.isInActiveSession = true
        container.mainContext.insert(record)
        container.mainContext.insert(LocalSyncState(userID: 1, cardCheckpoint: 99))
        try container.mainContext.save()

        let cardJSON = try XCTUnwrap(
            String(data: StorageCodec.encoder.encode(resetCard), encoding: .utf8)
        )
        let overview = StudyOverview(
            dueCount: 1,
            newCount: 0,
            reviewCount: 1,
            newCardsPerDay: 10,
            newCardsAvailableToday: 0
        )
        let overviewJSON = try XCTUnwrap(
            String(data: StorageCodec.encoder.encode(overview), encoding: .utf8)
        )
        let deferredUndo = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            switch request.url?.path {
            case "/api/study/reviews/undo":
                deferredUndo.hold(completion)
            case "/api/sync/feed":
                completion(.success(Self.response(
                    statusCode: 409,
                    data: Data(#"{"message":"Checkpoint expired"}"#.utf8)
                )))
            case "/api/study/known-kanji":
                completion(.success(Self.response(data: Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                ))))
            default:
                completion(.failure(URLError(.notConnectedToInternet)))
            }
        }
        let undoResponse = Self.response(data: Data(
            """
            {
              "reviewLogId": "undo-crossing-checkpoint-reset",
              "card": \(cardJSON),
              "overview": \(overviewJSON)
            }
            """.utf8
        ))
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
        XCTAssertEqual(store.cards.map(\.id), [resetCard.id])

        let undoTask = Task {
            try await store.undoReview(
                eventID: "undo-crossing-checkpoint-reset",
                cardBefore: resetCard
            )
        }
        await waitUntil { deferredUndo.hasPendingResponse }

        await store.synchronize()
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )

        deferredUndo.succeed(with: undoResponse)
        try await undoTask.value

        XCTAssertTrue(store.cards.isEmpty)
        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(records.map(\.id), [resetCard.id])
        XCTAssertFalse(try XCTUnwrap(records.first).isInActiveSession)
    }

    @MainActor
    func testOfflineDueCardsCannotEnterPresentedLesson() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let dueAt = Date.now.addingTimeInterval(3_600)
        let offlineReview = makeCard(
            id: "offline-review-due-during-lesson",
            expression: "後で復習",
            dueAt: dueAt
        )
        let record = LocalCardRecord(
            card: offlineReview,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(offlineReview)
        )
        record.isInActiveSession = false
        container.mainContext.insert(record)
        try container.mainContext.save()
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
        XCTAssertTrue(store.cards.isEmpty)

        store.beginLessonSessionPresentation()
        store.activateOfflineDueCards(at: dueAt.addingTimeInterval(1))

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertFalse(record.isInActiveSession)
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
        let canonicalizedDuplicate = makeCard(
            id: lessonCards[0].id.lowercased(),
            expression: "営業する",
            queueState: "new"
        )
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 3,
                newCount: 8,
                reviewCount: 3,
                newCardsPerDay: 20,
                newCardsAvailableToday: 8,
                lessonBatchSize: 2
            ),
            cards: [lessonCards[0], canonicalizedDuplicate, lessonCards[1]]
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
    func testSchedulerFailureDoesNotStageReviewOrMutateCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J000000000000000000000SF",
            expression: "安全",
            queueState: "review"
        )
        let originalPayload = try StorageCodec.encoder.encode(card)
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: originalPayload
            )
        )
        try container.mainContext.save()
        let requests = LockedCounter()
        let client = makeClient { request in
            _ = requests.next()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        let failure = FSRSReviewScheduler.InvalidRatingStatesError(
            missingGrades: [4],
            unexpectedGrades: []
        )
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            ),
            reviewProjection: { _, _, _ in throw failure }
        )

        let eventID = await store.recordReview(
            card: card,
            rating: .good,
            duration: nil
        )

        XCTAssertNil(eventID)
        XCTAssertEqual(store.syncStatus, .failed(failure.localizedDescription))
        XCTAssertEqual(requests.current, 0)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(try XCTUnwrap(records.first).payload, originalPayload)
        XCTAssertEqual(store.cards.first?.id, card.id)
        XCTAssertEqual(store.cards.first?.state, card.state)
    }

    @MainActor
    func testInvalidPersistedSchedulerTimestampDoesNotRequestAutomaticRetry() {
        let error = FSRSReviewScheduler.InvalidSchedulerTimestampError(field: "due")

        XCTAssertFalse(StudyStore.requiresAutomaticRetry(error))
    }

    @MainActor
    func testInvalidPersistedSchedulerTimestampRefetchesCanonicalCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let corrupted = makeCard(
            id: "corrupted-scheduler-card",
            expression: "修復",
            scheduler: .object([
                "due": .string("2027-01-15T08:00:00+14:01"),
                "last_review": .string("2027-01-14T08:00:00.000Z"),
                "state": .number(2),
            ])
        )
        let canonical = makeCard(
            id: corrupted.id,
            expression: "修復",
            scheduler: .object([
                "due": .string("2027-01-15T08:00:00.000Z"),
                "last_review": .string("2027-01-14T08:00:00.000Z"),
                "state": .number(2),
            ])
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: corrupted,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(corrupted)
            )
        )
        try container.mainContext.save()
        let canonicalObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(canonical)
        )
        let responseData = try JSONSerialization.data(
            withJSONObject: ["cards": [canonicalObject]]
        )
        let requests = LockedCounter()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/cards/batch")
            _ = requests.next()
            return Self.response(data: responseData)
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

        let eventID = await store.recordReview(
            card: corrupted,
            rating: .good,
            duration: nil
        )

        XCTAssertNil(eventID)
        XCTAssertEqual(requests.current, 1)
        XCTAssertEqual(store.syncStatus, .idle)
        XCTAssertEqual(store.cards.first?.state.scheduler, canonical.state.scheduler)
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        XCTAssertEqual(
            try StorageCodec.decoder.decode(StudyCard.self, from: record.payload).state.scheduler,
            canonical.state.scheduler
        )
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
    }

    @MainActor
    func testInvalidSchedulerRecoveryPreservesPendingLocalEdit() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let corrupted = makeCard(
            id: "pending-corrupted-card",
            expression: "未送信",
            scheduler: .object([
                "due": .string("2027-01-15T08:00:00+14:01"),
                "state": .number(2),
            ])
        )
        let payload = try StorageCodec.encoder.encode(corrupted)
        let record = LocalCardRecord(
            card: corrupted,
            userID: 1,
            queueIndex: 0,
            payload: payload
        )
        let locallyUpdatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        record.locallyUpdatedAt = locallyUpdatedAt
        container.mainContext.insert(record)
        container.mainContext.insert(
            PendingMutation(
                kind: "cardUpdate",
                userID: 1,
                resourceID: corrupted.id,
                payload: Data("pending-edit".utf8)
            )
        )
        try container.mainContext.save()
        let requests = LockedCounter()
        let client = makeClient { _ in
            _ = requests.next()
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        _ = await store.recordReview(card: corrupted, rating: .good, duration: nil)

        XCTAssertEqual(requests.current, 0)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(record.payload, payload)
        XCTAssertEqual(record.locallyUpdatedAt, locallyUpdatedAt)
        XCTAssertFalse(record.isInActiveSession)
    }

    @MainActor
    func testInvalidSchedulerRecoveryPreservesEditStagedDuringRefetch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let corrupted = makeCard(
            id: "in-flight-edit-corrupted-card",
            expression: "編集中",
            scheduler: .object([
                "due": .string("2027-01-15T08:00:00+14:01"),
                "state": .number(2),
            ])
        )
        let canonical = makeCard(
            id: corrupted.id,
            expression: "サーバー版",
            scheduler: .object([
                "due": .string("2027-01-15T08:00:00.000Z"),
                "state": .number(2),
            ])
        )
        let payload = try StorageCodec.encoder.encode(corrupted)
        let record = LocalCardRecord(
            card: corrupted,
            userID: 1,
            queueIndex: 0,
            payload: payload
        )
        container.mainContext.insert(record)
        try container.mainContext.save()
        let canonicalObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(canonical)
        )
        let responseData = try JSONSerialization.data(
            withJSONObject: ["cards": [canonicalObject]]
        )
        let deferredRefetch = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            XCTAssertEqual(request.url?.path, "/api/study/cards/batch")
            deferredRefetch.hold(completion)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        let reviewTask = Task { @MainActor in
            await store.recordReview(card: corrupted, rating: .good, duration: nil)
        }
        await deferredRefetch.waitUntilPending()
        container.mainContext.insert(
            PendingMutation(
                kind: "cardUpdate",
                userID: 1,
                resourceID: corrupted.id,
                payload: Data("in-flight-edit".utf8)
            )
        )
        try container.mainContext.save()
        deferredRefetch.succeed(with: Self.response(data: responseData))
        _ = await reviewTask.value

        XCTAssertEqual(record.payload, payload)
        XCTAssertFalse(record.isInActiveSession)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).count,
            1
        )
    }

    @MainActor
    func testInvalidSchedulerRecoveryPreservesPendingReviewState() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let corrupted = makeCard(
            id: "pending-review-corrupted-card",
            expression: "復習待ち",
            scheduler: .object([
                "due": .string("2027-01-15T08:00:00+14:01"),
                "state": .number(2),
            ])
        )
        let payload = try StorageCodec.encoder.encode(corrupted)
        let record = LocalCardRecord(
            card: corrupted,
            userID: 1,
            queueIndex: 0,
            payload: payload
        )
        container.mainContext.insert(record)
        let event = ReviewBatchRequest.Event(
            id: "pending-review-event",
            cardID: corrupted.id,
            rating: .good,
            reviewedAt: .now,
            durationMilliseconds: nil,
            clientEventID: "pending-review-client-event",
            deviceID: "device",
            clientCreatedAt: .now
        )
        container.mainContext.insert(
            PendingMutation(
                kind: "review",
                userID: 1,
                resourceID: corrupted.id,
                payload: try StorageCodec.encoder.encode(
                    PendingReviewPayload(
                        event: event,
                        cardBefore: PendingReviewCardState(card: corrupted)
                    )
                )
            )
        )
        try container.mainContext.save()
        let requests = LockedCounter()
        let client = makeClient { _ in
            _ = requests.next()
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        _ = await store.recordReview(card: corrupted, rating: .good, duration: nil)

        XCTAssertEqual(requests.current, 0)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(record.payload, payload)
        XCTAssertFalse(record.isInActiveSession)
        XCTAssertEqual(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).count,
            1
        )
    }

    @MainActor
    func testInvalidSchedulerRecoveryDeletesServerConfirmedMissingCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let corrupted = makeCard(
            id: "deleted-corrupted-card",
            expression: "削除済み",
            scheduler: .object([
                "due": .string("2027-01-15T08:00:00+14:01"),
                "state": .number(2),
            ])
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: corrupted,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(corrupted)
            )
        )
        try container.mainContext.save()
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"message":"Not found"}"#.utf8)
            )
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        _ = await store.recordReview(card: corrupted, rating: .good, duration: nil)

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(store.libraryCards.isEmpty)
        XCTAssertTrue(store.allCards.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
        XCTAssertEqual(store.syncStatus, .idle)
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
    func testRefreshDeDuplicatesCaseCanonicalizedServerCardIDs() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "01J00000000000000000000009", expression: "重複")
        let canonicalizedDuplicate = makeCard(
            id: card.id.lowercased(),
            expression: "重複"
        )
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 0,
                newCardsAvailableToday: 0
            ),
            cards: [card, canonicalizedDuplicate]
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
    func testRefreshDoesNotResurrectCardWithAliasedQuarantinedDelete() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "local-card-id",
            syncId: "server-card-id",
            expression: "削除"
        )
        let delete = PendingMutation(
            kind: "cardDelete",
            userID: 1,
            resourceID: "SERVER-CARD-ID",
            payload: Data()
        )
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
            masteryLevel: "guru",
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
        XCTAssertEqual(updated.masteryLevel, "guru")

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
        let initialRecord = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        initialRecord.queueIndex = 42
        try container.mainContext.save()
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
        XCTAssertEqual(records.first?.queueIndex, 0)
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
    func testRecentSessionRefreshDoesNotSuppressRetryOfTransientOutboxFailure() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let reviewCard = makeCard(
            id: "01J00000000000000000000AC",
            expression: "再試行"
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
        let reviewAttempts = LockedCounter()
        let sessionRefreshes = LockedCounter()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/card-review-events/batch":
                if reviewAttempts.next() <= 2 {
                    throw URLError(.networkConnectionLost)
                }
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data()
                )
            case "/api/sync/feed":
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8)
                )
            case "/api/study/known-kanji":
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(
                        #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                    )
                )
            case "/api/study/session/start":
                _ = sessionRefreshes.next()
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    sessionData
                )
            case "/api/study/offline-reserve":
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(
                        #"{"cards":[],"reserveDays":5,"generatedAt":"2026-07-25T12:00:00.000Z","horizonEndsAt":"2026-07-30T12:00:00.000Z"}"#.utf8
                    )
                )
            default:
                throw URLError(.badURL)
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
        defer { store.deactivate() }

        await store.synchronize()
        let lastSuccessfulSync = try XCTUnwrap(store.lastSyncAt)
        XCTAssertEqual(sessionRefreshes.current, 1)

        await store.recordReview(card: reviewCard, rating: .good, duration: nil)
        await store.synchronize()

        XCTAssertEqual(reviewAttempts.current, 2)
        XCTAssertEqual(sessionRefreshes.current, 2)
        XCTAssertEqual(
            store.lastSyncAt,
            lastSuccessfulSync,
            "A successful session refresh must not advance full-sync freshness."
        )
        XCTAssertFalse(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )

        await store.synchronizeIfNeeded(maxAge: .seconds(300))

        XCTAssertEqual(reviewAttempts.current, 3)
        XCTAssertEqual(sessionRefreshes.current, 3)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertGreaterThan(try XCTUnwrap(store.lastSyncAt), lastSuccessfulSync)
        XCTAssertEqual(store.syncStatus, .idle)
    }

    @MainActor
    func testFailedImmediateRetryReturnsToSessionFreshnessThrottle() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let reviewCard = makeCard(
            id: "01J00000000000000000000AD",
            expression: "抑制"
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
        let reviewAttempts = LockedCounter()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/card-review-events/batch":
                _ = reviewAttempts.next()
                throw URLError(.networkConnectionLost)
            case "/api/sync/feed":
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    Data(#"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8)
                )
            case "/api/study/known-kanji":
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    Data(#"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8)
                )
            case "/api/study/session/start":
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    sessionData
                )
            case "/api/study/offline-reserve":
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    Data(#"{"cards":[],"reserveDays":5,"generatedAt":"2026-07-25T12:00:00.000Z","horizonEndsAt":"2026-07-30T12:00:00.000Z"}"#.utf8)
                )
            default:
                throw URLError(.badURL)
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
        defer { store.deactivate() }

        await store.recordReview(card: reviewCard, rating: .good, duration: nil)
        await store.synchronize()
        await store.synchronizeIfNeeded(maxAge: .seconds(300))
        XCTAssertEqual(reviewAttempts.current, 3)

        await store.synchronizeIfNeeded(maxAge: .seconds(300))

        XCTAssertEqual(
            reviewAttempts.current,
            3,
            "A repeatedly failing outbox must return to the normal freshness throttle."
        )
    }

    @MainActor
    func testEagerReviewFlushFailureTriggersImmediateConditionalRetry() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let reviewCard = makeCard(
            id: "01J00000000000000000000AE",
            expression: "即時"
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
        let reviewAttempts = LockedCounter()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/card-review-events/batch":
                if reviewAttempts.next() == 1 {
                    throw URLError(.networkConnectionLost)
                }
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 201, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    Data()
                )
            case "/api/sync/feed":
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    Data(#"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8)
                )
            case "/api/study/known-kanji":
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    Data(#"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8)
                )
            case "/api/study/session/start":
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    sessionData
                )
            case "/api/study/offline-reserve":
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    Data(#"{"cards":[],"reserveDays":5,"generatedAt":"2026-07-25T12:00:00.000Z","horizonEndsAt":"2026-07-30T12:00:00.000Z"}"#.utf8)
                )
            default:
                throw URLError(.badURL)
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
        defer { store.deactivate() }

        await store.synchronize()
        await store.recordReview(card: reviewCard, rating: .good, duration: nil)
        XCTAssertEqual(reviewAttempts.current, 1)

        await store.synchronizeIfNeeded(maxAge: .seconds(300))

        XCTAssertEqual(reviewAttempts.current, 2)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
    }

    @MainActor
    func testOfflineReserveFromOldActivationCannotMergeAfterSameUserReactivation() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let staleReserveCard = makeCard(
            id: "reserve-from-old-activation",
            expression: "古い予備"
        )
        let emptySessionData = try sessionResponseData(cards: [])
        let staleReserveObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(staleReserveCard)
        )
        let staleReserveData = try JSONSerialization.data(withJSONObject: [
            "cards": [staleReserveObject],
            "reserveDays": 5,
            "generatedAt": "2026-07-25T12:00:00.000Z",
            "horizonEndsAt": "2026-07-30T12:00:00.000Z",
        ])
        let deferredReserve = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            switch request.url?.path {
            case "/api/sync/feed":
                completion(.success(Self.response(data: Data(
                    #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
                ))))
            case "/api/study/known-kanji":
                completion(.success(Self.response(data: Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                ))))
            case "/api/study/session/start":
                completion(.success(Self.response(data: emptySessionData)))
            case "/api/study/offline-reserve":
                deferredReserve.hold(completion)
            default:
                completion(.failure(URLError(.badURL)))
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

        let syncTask = Task { await store.synchronize() }
        await waitUntil { deferredReserve.hasPendingResponse }

        store.activate(userID: 2)
        store.activate(userID: 1)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )

        deferredReserve.succeed(with: Self.response(data: staleReserveData))
        await syncTask.value

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(store.libraryCards.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
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
        XCTAssertEqual(store.studySettings?.reviewTimeBudgetMinutes, 90)

        let saved = await store.updateNewCardsPerDay(24)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.studySettings?.newCardsPerDay, 24)
        XCTAssertNil(store.studySettingsErrorMessage)
    }

    @MainActor
    func testOlderSettingsRefreshCannotOverwriteNewerSavedSettings() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let deferredRefresh = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            XCTAssertEqual(request.url?.path, "/api/study/settings")
            if request.httpMethod == "PATCH" {
                completion(.success(Self.response(data: Data(
                    #"{"newCardsPerDay":24,"lessonBatchSize":8,"reviewTimeBudgetMinutes":150}"#.utf8
                ))))
            } else {
                deferredRefresh.hold(completion)
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

        let refresh = Task { await store.refreshStudySettings() }
        await waitUntil { deferredRefresh.hasPendingResponse }
        let saved = await store.updateStudySettings(
            newCardsPerDay: 24,
            lessonBatchSize: 8,
            reviewTimeBudgetMinutes: 150
        )
        XCTAssertTrue(saved)
        XCTAssertEqual(store.studySettings?.newCardsPerDay, 24)

        deferredRefresh.succeed(with: Self.response(data: Data(
            #"{"newCardsPerDay":12,"lessonBatchSize":5,"reviewTimeBudgetMinutes":90}"#.utf8
        )))
        await refresh.value

        XCTAssertEqual(store.studySettings?.newCardsPerDay, 24)
        XCTAssertEqual(store.studySettings?.lessonBatchSize, 8)
        XCTAssertEqual(store.studySettings?.reviewTimeBudgetMinutes, 150)
    }

    @MainActor
    func testSettingsRefreshCannotDiscardInFlightSave() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let deferredUpdate = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            XCTAssertEqual(request.url?.path, "/api/study/settings")
            if request.httpMethod == "PATCH" {
                deferredUpdate.hold(completion)
            } else {
                completion(.success(Self.response(data: Data(
                    #"{"newCardsPerDay":12,"lessonBatchSize":5,"reviewTimeBudgetMinutes":90}"#.utf8
                ))))
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

        let update = Task {
            await store.updateStudySettings(
                newCardsPerDay: 24,
                lessonBatchSize: 8,
                reviewTimeBudgetMinutes: 150
            )
        }
        await waitUntil { deferredUpdate.hasPendingResponse }
        await store.refreshStudySettings()
        XCTAssertEqual(store.studySettings?.newCardsPerDay, 12)

        deferredUpdate.succeed(with: Self.response(data: Data(
            #"{"newCardsPerDay":24,"lessonBatchSize":8,"reviewTimeBudgetMinutes":150}"#.utf8
        )))
        let saved = await update.value

        XCTAssertTrue(saved)
        XCTAssertEqual(store.studySettings?.newCardsPerDay, 24)
        XCTAssertEqual(store.studySettings?.lessonBatchSize, 8)
        XCTAssertEqual(store.studySettings?.reviewTimeBudgetMinutes, 150)
    }

    @MainActor
    func testOverviewRefreshPublishesSeparateN5VocabularyAndGrammarMastery() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/overview")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    #"{"dueCount":0,"newCount":0,"reviewCount":0,"newCardsPerDay":20,"jlptMastery":{"N5":{"vocabulary":{"masteryPercent":34,"known":233,"matched":280,"covered":280,"total":684},"grammar":{"masteryPercent":21,"known":16,"matched":29,"covered":29,"total":77}}}}"#.utf8
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

        await store.refreshOverview()

        XCTAssertEqual(store.overview?.jlptMastery?.n5.vocabulary.masteryPercent, 34)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.vocabulary.known, 233)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.vocabulary.matched, 280)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.vocabulary.total, 684)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.grammar.masteryPercent, 21)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.grammar.known, 16)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.grammar.matched, 29)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.grammar.total, 77)
        XCTAssertFalse(store.isRefreshingOverview)
        XCTAssertNil(store.overviewRefreshErrorMessage)
    }

    @MainActor
    func testOverviewRefreshPreservesMasteryWhenResponseOmitsIt() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        container.mainContext.insert(LocalStudyOverviewSnapshot(
            userID: 1,
            payload: try StorageCodec.encoder.encode(StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 20,
                newCardsAvailableToday: 0,
                jlptMastery: StudyJLPTMastery(
                    n5: StudyJLPTLevelMastery(
                        vocabulary: StudyJLPTMasteryMetric(
                            masteryPercent: 8,
                            covered: 83,
                            total: 684
                        ),
                        grammar: StudyJLPTMasteryMetric(
                            masteryPercent: 46,
                            covered: 36,
                            total: 77
                        )
                    )
                )
            ))
        ))
        try container.mainContext.save()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/overview")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    #"{"dueCount":2,"newCount":0,"reviewCount":2,"newCardsPerDay":20}"#.utf8
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

        await store.refreshOverview()

        XCTAssertEqual(store.overview?.dueCount, 2)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.vocabulary.masteryPercent, 8)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.grammar.masteryPercent, 46)
    }

    @MainActor
    func testOverviewRefreshCannotOverwriteNewerSavedSettings() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let deferredOverview = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            switch (request.url?.path, request.httpMethod) {
            case ("/api/study/settings", "GET"):
                completion(.success(Self.response(data: Data(
                    #"{"newCardsPerDay":12,"lessonBatchSize":5,"reviewTimeBudgetMinutes":90}"#.utf8
                ))))
            case ("/api/study/settings", "PATCH"):
                completion(.success(Self.response(data: Data(
                    #"{"newCardsPerDay":24,"lessonBatchSize":8,"reviewTimeBudgetMinutes":150}"#.utf8
                ))))
            case ("/api/study/overview", "GET"):
                deferredOverview.hold(completion)
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                completion(.failure(URLError(.unsupportedURL)))
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
        await store.refreshStudySettings()

        let refresh = Task { await store.refreshOverview() }
        await deferredOverview.waitUntilPending()
        let saved = await store.updateStudySettings(
            newCardsPerDay: 24,
            lessonBatchSize: 8,
            reviewTimeBudgetMinutes: 150
        )
        XCTAssertTrue(saved)

        deferredOverview.succeed(with: Self.response(data: Data(
            #"{"dueCount":3,"newCount":4,"reviewCount":7,"newCardsPerDay":12,"lessonBatchSize":5,"reviewTimeBudgetMinutes":90}"#.utf8
        )))
        await refresh.value

        XCTAssertEqual(store.overview?.dueCount, 3)
        XCTAssertEqual(store.studySettings?.newCardsPerDay, 24)
        XCTAssertEqual(store.studySettings?.lessonBatchSize, 8)
        XCTAssertEqual(store.studySettings?.reviewTimeBudgetMinutes, 150)
        XCTAssertEqual(store.overview?.newCardsPerDay, 24)
        XCTAssertEqual(store.overview?.lessonBatchSize, 8)
        XCTAssertEqual(store.overview?.reviewTimeBudgetMinutes, 150)
    }

    @MainActor
    func testSessionRefreshPreservesBudgetAndMasteryWhenResponseFieldsAreAbsent() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        container.mainContext.insert(LocalStudyOverviewSnapshot(
            userID: 1,
            payload: try StorageCodec.encoder.encode(StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 20,
                newCardsAvailableToday: 0,
                jlptMastery: StudyJLPTMastery(
                    n5: StudyJLPTLevelMastery(
                        vocabulary: StudyJLPTMasteryMetric(
                            masteryPercent: 8,
                            covered: 83,
                            total: 684
                        ),
                        grammar: StudyJLPTMasteryMetric(
                            masteryPercent: 46,
                            covered: 36,
                            total: 77
                        )
                    )
                )
            ))
        ))
        try container.mainContext.save()
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 0,
                reviewCount: 0,
                newCardsPerDay: 20,
                newCardsAvailableToday: 0,
                learningReadiness: StudyLearningReadiness(
                    recommendation: "ready",
                    readinessLevel: "ready",
                    sampleSize: 40,
                    sufficientData: true,
                    recentRecall: 0.95,
                    targetRecall: 0.9,
                    dueBacklog: 0,
                    apprenticeCount: 0,
                    projectedSevenDayReviews: 28,
                    timedReviewSampleSize: 40,
                    medianReviewDurationSeconds: 900,
                    projectedDailyReviewMinutes: 60,
                    reviewTimeBudgetMinutes: nil,
                    reviewTimeHeadroomMinutes: nil,
                    suggestedBatchSize: 5
                )
            ),
            cards: []
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/settings":
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(
                        #"{"newCardsPerDay":20,"lessonBatchSize":5,"reviewTimeBudgetMinutes":150}"#.utf8
                    )
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
        try await store.refreshSession()

        XCTAssertEqual(store.studySettings?.reviewTimeBudgetMinutes, 150)
        XCTAssertEqual(store.overview?.reviewTimeBudgetMinutes, 150)
        XCTAssertEqual(store.overview?.learningReadiness?.reviewTimeBudgetMinutes, 150)
        XCTAssertEqual(store.overview?.learningReadiness?.reviewTimeHeadroomMinutes, 90)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.vocabulary.masteryPercent, 8)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.grammar.masteryPercent, 46)
    }

    @MainActor
    func testSettingsRefreshUpdatesOverviewReadinessBudget() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 0,
                reviewCount: 0,
                newCardsPerDay: 20,
                newCardsAvailableToday: 0,
                learningReadiness: StudyLearningReadiness(
                    recommendation: "ready",
                    readinessLevel: "ready",
                    sampleSize: 40,
                    sufficientData: true,
                    recentRecall: 0.95,
                    targetRecall: 0.9,
                    dueBacklog: 0,
                    apprenticeCount: 0,
                    projectedSevenDayReviews: 28,
                    timedReviewSampleSize: 40,
                    medianReviewDurationSeconds: 900,
                    projectedDailyReviewMinutes: 60,
                    reviewTimeBudgetMinutes: 90,
                    reviewTimeHeadroomMinutes: 30,
                    suggestedBatchSize: 5
                )
            ),
            cards: []
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let client = makeClient { request in
            switch request.url?.path {
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
            case "/api/study/settings":
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(
                        #"{"newCardsPerDay":24,"lessonBatchSize":8,"reviewTimeBudgetMinutes":150}"#.utf8
                    )
                )
            default:
                throw URLError(.unsupportedURL)
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

        try await store.refreshSession()
        await store.refreshStudySettings()

        XCTAssertEqual(store.overview?.newCardsPerDay, 24)
        XCTAssertEqual(store.overview?.lessonBatchSize, 8)
        XCTAssertEqual(store.studySettings?.reviewTimeBudgetMinutes, 150)
        XCTAssertEqual(store.overview?.reviewTimeBudgetMinutes, 150)
        XCTAssertEqual(store.overview?.learningReadiness?.reviewTimeBudgetMinutes, 150)
        XCTAssertEqual(store.overview?.learningReadiness?.reviewTimeHeadroomMinutes, 90)
    }

    @MainActor
    func testStudySettingsUpdateSendsAnExplicitReviewBudget() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/settings")
            XCTAssertEqual(request.httpMethod, "PATCH")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Int]
            )
            XCTAssertEqual(body, [
                "lessonBatchSize": 5,
                "newCardsPerDay": 20,
                "reviewTimeBudgetMinutes": 150,
            ])

            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    #"{"newCardsPerDay":20,"lessonBatchSize":5,"reviewTimeBudgetMinutes":150}"#.utf8
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

        let saved = await store.updateStudySettings(
            newCardsPerDay: 20,
            lessonBatchSize: 5,
            reviewTimeBudgetMinutes: 150
        )

        XCTAssertTrue(saved)
        XCTAssertEqual(store.studySettings?.reviewTimeBudgetMinutes, 150)
    }

    @MainActor
    func testLegacySettingsResponsePreservesExplicitReviewBudget() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/settings")
            XCTAssertEqual(request.httpMethod, "PATCH")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"newCardsPerDay":20,"lessonBatchSize":5}"#.utf8)
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

        let saved = await store.updateStudySettings(
            newCardsPerDay: 20,
            lessonBatchSize: 5,
            reviewTimeBudgetMinutes: 150
        )

        XCTAssertTrue(saved)
        XCTAssertEqual(store.studySettings?.reviewTimeBudgetMinutes, 150)
    }

    @MainActor
    func testStaleStudySettingsResponseCannotPopulateReactivatedAccount() async throws {
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
        store.activate(userID: 1)
        gate.release()
        await refresh.value

        XCTAssertNil(store.studySettings)
        XCTAssertNil(store.studySettingsErrorMessage)
    }

    @MainActor
    func testStaleStudySettingsUpdateCannotPopulateReactivatedAccount() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let gate = LockedRequestGate()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/settings")
            XCTAssertEqual(request.httpMethod, "PATCH")
            gate.markStarted()
            gate.waitForRelease()
            return Self.response(data: Data(
                #"{"newCardsPerDay":24,"lessonBatchSize":8,"reviewTimeBudgetMinutes":150}"#.utf8
            ))
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

        let update = Task {
            await store.updateStudySettings(
                newCardsPerDay: 24,
                lessonBatchSize: 8,
                reviewTimeBudgetMinutes: 150
            )
        }
        await waitUntil { gate.hasStarted }

        store.activate(userID: 2)
        store.activate(userID: 1)
        gate.release()
        let saved = await update.value

        XCTAssertFalse(saved)
        XCTAssertNil(store.studySettings)
        XCTAssertNil(store.studySettingsErrorMessage)
        XCTAssertFalse(store.isUpdatingStudySettings)
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
    func testStaleCardMutationDrainCannotReloadPreviousAccountsCards() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let userOneCard = makeCard(
            id: "01J00000000000000000000B1",
            expression: "前の利用者"
        )
        let userTwoCard = makeCard(
            id: "01J00000000000000000000B2",
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
        let userOneCardID = userOneCard.id
        let serverCardData = try StorageCodec.encoder.encode(userOneCard)
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/api/study/cards/\(userOneCardID)")
            gate.markStarted()
            gate.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                serverCardData
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

        let update = Task {
            try await store.updateCard(
                userOneCard,
                prompt: "更新中",
                reading: "こうしんちゅう",
                answer: "updating"
            )
        }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)

        store.activate(userID: 2)
        XCTAssertEqual(store.cards.map(\.id), [userTwoCard.id])
        XCTAssertEqual(store.libraryCards.map(\.id), [userTwoCard.id])
        gate.release()
        try await update.value

        XCTAssertEqual(store.cards.map(\.id), [userTwoCard.id])
        XCTAssertEqual(store.libraryCards.map(\.id), [userTwoCard.id])
        XCTAssertEqual(store.syncStatus, .idle)
    }

    @MainActor
    func testCancelledReviewFromPreviousAccountCannotFailCurrentAccount() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let userOneCard = makeCard(
            id: "01J00000000000000000000B3",
            expression: "前の利用者の復習"
        )
        let userTwoCard = makeCard(
            id: "01J00000000000000000000B4",
            expression: "現在の利用者の復習"
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
            XCTAssertEqual(request.url?.path, "/api/card-review-events/batch")
            gate.markStarted()
            gate.waitForRelease()
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

        let review = Task {
            await store.recordReview(card: userOneCard, rating: .good, duration: nil)
        }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)

        store.activate(userID: 2)
        XCTAssertEqual(store.cards.map(\.id), [userTwoCard.id])
        XCTAssertEqual(store.syncStatus, .idle)
        gate.release()
        _ = await review.value

        XCTAssertEqual(store.cards.map(\.id), [userTwoCard.id])
        XCTAssertEqual(store.libraryCards.map(\.id), [userTwoCard.id])
        XCTAssertEqual(store.syncStatus, .idle)
    }

    @MainActor
    func testCancelledReviewCannotFailReactivatedSameAccount() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000B5",
            expression: "再認証前の復習"
        )
        container.mainContext.insert(LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        ))
        try container.mainContext.save()

        let gate = LockedRequestGate()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/card-review-events/batch")
            gate.markStarted()
            gate.waitForRelease()
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

        let review = Task {
            await store.recordReview(card: card, rating: .good, duration: nil)
        }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)

        store.deactivate()
        store.activate(userID: 1)
        XCTAssertEqual(store.syncStatus, .idle)
        gate.release()
        _ = await review.value

        XCTAssertEqual(store.syncStatus, .idle)
    }

    @MainActor
    func testStaleSynchronizationCannotFailReactivatedSameAccount() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
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
        let sessionData = try JSONSerialization.data(
            withJSONObject: ["data": sessionObject]
        )
        let gate = LockedRequestGate()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(data: Data(
                    #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
                ))
            case "/api/study/known-kanji":
                return Self.response(data: Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                ))
            case "/api/study/session/start":
                return Self.response(data: sessionData)
            case "/api/study/offline-reserve":
                gate.markStarted()
                gate.waitForRelease()
                throw URLError(.notConnectedToInternet)
            default:
                throw URLError(.badURL)
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

        store.deactivate()
        store.activate(userID: 1)
        XCTAssertEqual(store.syncStatus, .idle)
        gate.release()
        await synchronization.value

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
    func testDiscardingRejectedCardDeleteReleasesServerReconciliation() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "local-card-id",
            syncId: "server-card-id",
            expression: "残す"
        )
        let delete = PendingMutation(
            kind: "cardDelete",
            userID: 1,
            resourceID: "SERVER-CARD-ID",
            payload: Data()
        )
        delete.lastError = "HTTP 409: Delete conflict"
        container.mainContext.insert(delete)
        // Match deleteCard(_:)'s optimistic state: the local replica is gone
        // before the server rejects the queued deletion.
        try container.mainContext.save()

        let sessionData = try sessionResponseData(cards: [card])
        let cardData = try StorageCodec.encoder.encode(card)
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/cards/batch":
                let cardObject = try JSONSerialization.jsonObject(with: cardData)
                return Self.response(data: try JSONSerialization.data(
                    withJSONObject: ["cards": [cardObject]]
                ))
            case "/api/sync/feed":
                return Self.response(data: Data(
                    #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
                ))
            case "/api/study/known-kanji":
                return Self.response(data: Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                ))
            case "/api/study/session/start":
                return Self.response(data: sessionData)
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

        XCTAssertEqual(store.failedStudyChanges.map(\.kind), [.cardDelete])
        XCTAssertTrue(store.libraryCards.isEmpty)

        try await store.discardFailedStudyChange(id: delete.id)

        XCTAssertTrue(store.failedStudyChanges.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertEqual(store.libraryCards.map(\.id), [card.id])
    }

    @MainActor
    func testDiscardingRejectedCardUpdateRestoresCanonicalServerContent() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let serverCard = makeCard(
            id: "01J00000000000000000000F3",
            expression: "サーバー"
        )
        let localCard = makeCard(
            id: serverCard.id,
            expression: "破棄する編集"
        )
        let record = LocalCardRecord(
            card: localCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(localCard)
        )
        record.locallyUpdatedAt = .now
        let update = PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: serverCard.id,
            payload: try StorageCodec.encoder.encode(UpdateStudyCardRequest(
                prompt: localCard.prompt,
                answer: localCard.answer
            ))
        )
        update.lastError = "HTTP 422: Invalid card"
        container.mainContext.insert(record)
        container.mainContext.insert(update)
        try container.mainContext.save()

        let cardData = try StorageCodec.encoder.encode(serverCard)
        let sessionData = try sessionResponseData(cards: [serverCard])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/cards/batch":
                let cardObject = try JSONSerialization.jsonObject(with: cardData)
                return Self.response(data: try JSONSerialization.data(
                    withJSONObject: ["cards": [cardObject]]
                ))
            case "/api/sync/feed":
                return Self.response(data: Data(
                    #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
                ))
            case "/api/study/known-kanji":
                return Self.response(data: Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                ))
            case "/api/study/session/start":
                return Self.response(data: sessionData)
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

        XCTAssertEqual(store.libraryCards.first?.promptText, "破棄する編集")

        try await store.discardFailedStudyChange(id: update.id)

        XCTAssertEqual(store.libraryCards.first?.promptText, "サーバー")
        XCTAssertNil(record.locallyUpdatedAt)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testDiscardingOlderRejectedCardUpdatePreservesNewerPendingEdit() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let serverCard = makeCard(
            id: "01J00000000000000000000F7",
            expression: "サーバー"
        )
        let localCard = makeCard(
            id: serverCard.id,
            expression: "最新の編集"
        )
        let record = LocalCardRecord(
            card: localCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(localCard)
        )
        record.locallyUpdatedAt = .now
        let rejectedUpdate = PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: serverCard.id,
            payload: try StorageCodec.encoder.encode(UpdateStudyCardRequest(
                prompt: serverCard.prompt,
                answer: serverCard.answer
            ))
        )
        rejectedUpdate.lastError = "HTTP 422: Invalid card"
        let newerUpdate = PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: serverCard.id.uppercased(),
            payload: try StorageCodec.encoder.encode(UpdateStudyCardRequest(
                prompt: localCard.prompt,
                answer: localCard.answer
            ))
        )
        container.mainContext.insert(record)
        container.mainContext.insert(rejectedUpdate)
        container.mainContext.insert(newerUpdate)
        try container.mainContext.save()

        let cardData = try StorageCodec.encoder.encode(serverCard)
        let cardObject = try JSONSerialization.jsonObject(with: cardData)
        let canonicalData = try JSONSerialization.data(
            withJSONObject: ["cards": [cardObject]]
        )
        let client = makeClient { request in
            if request.url?.path == "/api/study/cards/batch" {
                return Self.response(data: canonicalData)
            }
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

        try await store.discardFailedStudyChange(id: rejectedUpdate.id)

        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(pending.map(\.id), [newerUpdate.id])
        XCTAssertNotNil(record.locallyUpdatedAt)
        let retainedCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: record.payload
        )
        XCTAssertEqual(retainedCard.promptText, "最新の編集")
        XCTAssertEqual(store.libraryCards.first?.promptText, "最新の編集")
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testDiscardingRejectedCardUpdateRemovesCardMissingFromServer() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000F5",
            expression: "既に削除"
        )
        let record = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        record.locallyUpdatedAt = .now
        let update = PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: card.id,
            payload: try StorageCodec.encoder.encode(UpdateStudyCardRequest(
                prompt: card.prompt,
                answer: card.answer
            ))
        )
        update.lastError = "HTTP 404: Card not found"
        let dependentReview = PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: card.id.uppercased(),
            payload: Data()
        )
        container.mainContext.insert(record)
        container.mainContext.insert(update)
        container.mainContext.insert(dependentReview)
        try container.mainContext.save()

        let client = makeClient { request in
            if request.url?.path == "/api/study/cards/batch" {
                return Self.response(data: Data(#"{"cards":[]}"#.utf8))
            }
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

        try await store.discardFailedStudyChange(id: update.id)

        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
        XCTAssertTrue(store.libraryCards.isEmpty)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testDiscardingRejectedCardCreateRemovesLocalCardAndDependentChanges() async throws {
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
        try await store.createCard(expression: "仮", reading: "かり", meaning: "temporary")
        let card = try XCTUnwrap(store.libraryCards.first)
        let create = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                .first(where: { $0.kind == "cardCreate" })
        )
        create.lastError = "HTTP 422: Invalid card"
        let dependentUpdate = PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: card.id.uppercased(),
            payload: try StorageCodec.encoder.encode(UpdateStudyCardRequest(
                prompt: card.prompt,
                answer: card.answer
            ))
        )
        container.mainContext.insert(dependentUpdate)
        try container.mainContext.save()
        store.reloadFailedStudyChanges()

        try await store.discardFailedStudyChange(id: create.id)

        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
        XCTAssertTrue(store.libraryCards.isEmpty)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testRetryingRejectedCardUpdateDrainsCardOutbox() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let serverCard = makeCard(
            id: "01J00000000000000000000F4",
            expression: "再送信"
        )
        let payload = try StorageCodec.encoder.encode(UpdateStudyCardRequest(
            prompt: serverCard.prompt,
            answer: serverCard.answer
        ))
        let record = LocalCardRecord(
            card: serverCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(serverCard)
        )
        record.locallyUpdatedAt = .now
        let mutation = PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: serverCard.id,
            payload: payload
        )
        mutation.lastError = "HTTP 422: Invalid card"
        container.mainContext.insert(record)
        container.mainContext.insert(mutation)
        try container.mainContext.save()
        let serverCardID = serverCard.id
        let serverCardData = try StorageCodec.encoder.encode(serverCard)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/cards/\(serverCardID)")
            XCTAssertEqual(request.httpMethod, "PATCH")
            return Self.response(data: serverCardData)
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

        try await store.retryFailedStudyChange(id: mutation.id)

        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertNil(record.locallyUpdatedAt)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testRetryingRejectedReviewUsesOriginalPayloadAndClearsFailure() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let offlineClient = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(
            initialUserID: 1,
            api: offlineClient,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: offlineClient,
                context: container.mainContext
            )
        )
        let card = makeCard(
            id: "01J00000000000000000000F1",
            expression: "再試行"
        )
        let recordedEventID = await store.recordReview(
            card: card,
            rating: .good,
            duration: nil
        )
        let eventID = try XCTUnwrap(recordedEventID)
        let mutation = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>()).first
        )
        let originalPayload = mutation.payload
        mutation.lastError = "HTTP 422: Invalid review"
        try container.mainContext.save()
        store.reloadFailedStudyChanges()

        XCTAssertEqual(store.failedStudyChanges.map(\.kind), [.review])
        XCTAssertTrue(store.failedStudyChanges.first?.detail.contains("Good") == true)

        let uploadedEventIDs = LockedRequestPaths()
        MockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(
                with: try requestBody(request)
            ) as? [String: Any]
            let events = try XCTUnwrap(body?["events"] as? [[String: Any]])
            uploadedEventIDs.append(try XCTUnwrap(events.first?["id"] as? String))
            return Self.response(statusCode: 204, data: Data())
        }

        try await store.retryFailedStudyChange(id: mutation.id)

        XCTAssertEqual(uploadedEventIDs.values, [eventID])
        let uploadedPayload = try XCTUnwrap(uploadedEventIDs.values.first)
        let original = try StorageCodec.decoder.decode(
            PendingReviewPayload.self,
            from: originalPayload
        )
        XCTAssertEqual(uploadedPayload, original.event.id)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
    }

    @MainActor
    func testDiscardingRejectedReviewRestoresCanonicalServerCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let cardBefore = makeCard(
            id: "01J000000000000000000000F6",
            expression: "取り消す",
            dueAt: Date(timeIntervalSince1970: 1_700_000_000),
            masteryLevel: "learning"
        )
        let cardAfter = makeCard(
            id: cardBefore.id,
            expression: "取り消す",
            dueAt: Date(timeIntervalSince1970: 1_800_000_000),
            masteryLevel: "mastered"
        )
        let record = LocalCardRecord(
            card: cardAfter,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(cardAfter)
        )
        let event = ReviewBatchRequest.Event(
            id: "01J00000000000000000000E6",
            cardID: cardBefore.id,
            rating: .good,
            reviewedAt: .now,
            durationMilliseconds: nil,
            clientEventID: "discard-review",
            deviceID: "device",
            clientCreatedAt: .now
        )
        let mutation = PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: cardBefore.id,
            payload: try StorageCodec.encoder.encode(
                PendingReviewPayload(
                    event: event,
                    cardBefore: PendingReviewCardState(card: cardBefore)
                )
            )
        )
        mutation.lastError = "HTTP 422: Invalid review"
        container.mainContext.insert(record)
        container.mainContext.insert(mutation)
        try container.mainContext.save()
        let cardData = try StorageCodec.encoder.encode(cardBefore)
        let cardObject = try JSONSerialization.jsonObject(with: cardData)
        let canonicalData = try JSONSerialization.data(
            withJSONObject: ["cards": [cardObject]]
        )
        let client = makeClient { request in
            if request.url?.path == "/api/study/cards/batch" {
                return Self.response(data: canonicalData)
            }
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

        try await store.discardFailedStudyChange(id: mutation.id)

        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        let restoredRecord = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let restoredCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: restoredRecord.payload
        )
        XCTAssertEqual(restoredCard.state.dueAt, cardBefore.state.dueAt)
        XCTAssertEqual(restoredCard.masteryLevel, cardBefore.masteryLevel)
        XCTAssertEqual(store.libraryCards.first?.state.dueAt, cardBefore.state.dueAt)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testDiscardingRejectedReviewUsesServerIDAndRemovesStaleLocalCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let localID = "8D748A0E-2EE9-49A9-8A32-7B9E4187C273"
        let serverID = "01J000000000000000000000F8"
        let cardBefore = makeCard(
            id: localID,
            syncId: serverID,
            expression: "削除済み"
        )
        let cardAfter = makeCard(
            id: localID,
            syncId: serverID,
            expression: "削除済み",
            dueAt: Date(timeIntervalSince1970: 1_800_000_000),
            masteryLevel: "mastered"
        )
        let record = LocalCardRecord(
            card: cardAfter,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(cardAfter)
        )
        let event = ReviewBatchRequest.Event(
            id: "01J00000000000000000000E8",
            cardID: localID,
            rating: .good,
            reviewedAt: .now,
            durationMilliseconds: nil,
            clientEventID: "discard-stale-review",
            deviceID: "device",
            clientCreatedAt: .now
        )
        let mutation = PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: localID,
            payload: try StorageCodec.encoder.encode(
                PendingReviewPayload(
                    event: event,
                    cardBefore: PendingReviewCardState(card: cardBefore)
                )
            )
        )
        mutation.lastError = "HTTP 422: The selected card id is invalid."
        container.mainContext.insert(record)
        container.mainContext.insert(mutation)
        try container.mainContext.save()

        let requestedCardIDs = LockedRequestPaths()
        let client = makeClient { request in
            if request.url?.path == "/api/study/cards/batch" {
                let body = try JSONSerialization.jsonObject(
                    with: try requestBody(request)
                ) as? [String: Any]
                let ids = try XCTUnwrap(body?["ids"] as? [String])
                requestedCardIDs.append(try XCTUnwrap(ids.first))
                return Self.response(data: Data(#"{"cards":[]}"#.utf8))
            }
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

        XCTAssertEqual(store.failedStudyChanges.count, 1)
        XCTAssertFalse(try XCTUnwrap(store.failedStudyChanges.first).isRetryable)

        try await store.retryFailedStudyChange(id: mutation.id)

        XCTAssertTrue(requestedCardIDs.values.isEmpty)
        XCTAssertEqual(store.failedStudyChanges.map(\.id), [mutation.id])

        try await store.discardFailedStudyChange(id: mutation.id)

        XCTAssertEqual(requestedCardIDs.values, [serverID.lowercased()])
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
        XCTAssertTrue(store.libraryCards.isEmpty)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testDiscardingRejectedReviewUsesServerIDAndPreservesCanonicalCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let localID = "14A15A14-E665-4021-907B-A0FC75C18AFB"
        let serverID = "01J000000000000000000000F9"
        let cardBefore = makeCard(
            id: localID,
            syncId: serverID,
            expression: "残っている",
            dueAt: Date(timeIntervalSince1970: 1_700_000_000),
            masteryLevel: "learning"
        )
        let cardAfter = makeCard(
            id: localID,
            syncId: serverID,
            expression: "残っている",
            dueAt: Date(timeIntervalSince1970: 1_800_000_000),
            masteryLevel: "mastered"
        )
        let record = LocalCardRecord(
            card: cardAfter,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(cardAfter)
        )
        let event = ReviewBatchRequest.Event(
            id: "01J00000000000000000000E9",
            cardID: localID,
            rating: .good,
            reviewedAt: .now,
            durationMilliseconds: nil,
            clientEventID: "discard-imported-review",
            deviceID: "device",
            clientCreatedAt: .now
        )
        let mutation = PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: localID,
            payload: try StorageCodec.encoder.encode(
                PendingReviewPayload(
                    event: event,
                    cardBefore: PendingReviewCardState(card: cardBefore)
                )
            )
        )
        mutation.lastError = "HTTP 422: Invalid review"
        container.mainContext.insert(record)
        container.mainContext.insert(mutation)
        try container.mainContext.save()

        let requestedCardIDs = LockedRequestPaths()
        let cardData = try StorageCodec.encoder.encode(cardBefore)
        let cardObject = try JSONSerialization.jsonObject(with: cardData)
        let canonicalData = try JSONSerialization.data(
            withJSONObject: ["cards": [cardObject]]
        )
        let client = makeClient { request in
            if request.url?.path == "/api/study/cards/batch" {
                let body = try JSONSerialization.jsonObject(
                    with: try requestBody(request)
                ) as? [String: Any]
                let ids = try XCTUnwrap(body?["ids"] as? [String])
                requestedCardIDs.append(try XCTUnwrap(ids.first))
                return Self.response(data: canonicalData)
            }
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

        try await store.discardFailedStudyChange(id: mutation.id)

        XCTAssertEqual(requestedCardIDs.values, [serverID.lowercased()])
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        let restoredRecord = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let restoredCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: restoredRecord.payload
        )
        XCTAssertEqual(restoredCard.id, localID)
        XCTAssertEqual(restoredCard.syncId, serverID)
        XCTAssertEqual(restoredCard.state.dueAt, cardBefore.state.dueAt)
        XCTAssertEqual(restoredCard.masteryLevel, cardBefore.masteryLevel)
        XCTAssertEqual(store.libraryCards.first?.state.dueAt, cardBefore.state.dueAt)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testDiscardingRejectedReviewWithNoServerULIDSkipsCanonicalFetch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let localID = "8D748A0E-2EE9-49A9-8A32-7B9E4187C273"
        let card = makeCard(id: localID, expression: "孤立したカード")
        let record = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        let event = ReviewBatchRequest.Event(
            id: "01J00000000000000000000EA",
            cardID: localID,
            rating: .good,
            reviewedAt: .now,
            durationMilliseconds: nil,
            clientEventID: "discard-invalid-ulid-review",
            deviceID: "device",
            clientCreatedAt: .now
        )
        let mutation = PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: localID,
            payload: try StorageCodec.encoder.encode(
                PendingReviewPayload(
                    event: event,
                    cardBefore: PendingReviewCardState(card: card)
                )
            )
        )
        mutation.lastError = "HTTP 422: The selected card id is invalid."
        container.mainContext.insert(record)
        container.mainContext.insert(mutation)
        try container.mainContext.save()

        let requests = LockedRequestPaths()
        let client = makeClient { request in
            requests.append(request.url?.path ?? "")
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

        try await store.discardFailedStudyChange(id: mutation.id)

        XCTAssertFalse(requests.values.contains("/api/study/cards/batch"))
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testOfflineRetryKeepsRejectedReviewPayloadPending() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let card = makeCard(
            id: "01J00000000000000000000F2",
            expression: "保留"
        )
        let event = ReviewBatchRequest.Event(
            id: "01J00000000000000000000E1",
            cardID: card.id,
            rating: .hard,
            reviewedAt: .now,
            durationMilliseconds: nil,
            clientEventID: "client-event",
            deviceID: "device",
            clientCreatedAt: .now
        )
        let payload = try StorageCodec.encoder.encode(
            PendingReviewPayload(
                event: event,
                cardBefore: PendingReviewCardState(card: card)
            )
        )
        let mutation = PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: card.id,
            payload: payload
        )
        mutation.lastError = "HTTP 422: Invalid review"
        container.mainContext.insert(mutation)
        try container.mainContext.save()
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

        do {
            try await store.retryFailedStudyChange(id: mutation.id)
            XCTFail("Expected retry to remain pending while offline")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }

        let retained = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>()).first
        )
        XCTAssertEqual(retained.id, mutation.id)
        XCTAssertEqual(retained.payload, payload)
        XCTAssertNil(retained.lastError)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
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
        XCTAssertNil(
            store.lastSyncAt,
            "A quarantined mutation is a partial sync, even though its session data is usable."
        )
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
    func testReviewOverviewSnapshotFlushesWithoutWaitingForNetwork() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000019",
            expression: "魚"
        )
        container.mainContext.insert(LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        ))
        container.mainContext.insert(LocalStudyOverviewSnapshot(
            userID: 1,
            payload: try StorageCodec.encoder.encode(StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 10,
                newCardsAvailableToday: 0,
                jlptMastery: StudyJLPTMastery(
                    n5: StudyJLPTLevelMastery(
                        vocabulary: StudyJLPTMasteryMetric(
                            masteryPercent: 8,
                            covered: 83,
                            total: 684
                        ),
                        grammar: StudyJLPTMasteryMetric(
                            masteryPercent: 46,
                            covered: 36,
                            total: 77
                        )
                    )
                )
            ))
        ))
        try container.mainContext.save()
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

        await store.recordReview(card: card, rating: .good, duration: nil)
        store.persistCachedState()

        let verificationContext = ModelContext(container)
        let snapshot = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<LocalStudyOverviewSnapshot>()).first
        )
        let restored = try StorageCodec.decoder.decode(
            StudyOverview.self,
            from: snapshot.payload
        )
        XCTAssertEqual(restored.dueCount, 0)
        XCTAssertEqual(restored.jlptMastery?.n5.vocabulary.masteryPercent, 8)
        XCTAssertEqual(restored.jlptMastery?.n5.grammar.masteryPercent, 46)
    }

    @MainActor
    func testReviewFromStaleSnapshotUpdatesCanonicalRecordWithoutDuplicate() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let clientID = "01J000000000000000000000RV"
        let canonicalID = clientID.lowercased()
        let staleCard = makeCard(
            id: clientID,
            expression: "古い識別子",
            queueState: "review"
        )
        let canonicalCard = makeCard(
            id: canonicalID,
            expression: "現在のローカル内容",
            queueState: "review"
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
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let mediaCache = MediaCache(
            initialUserID: 1,
            api: client,
            context: container.mainContext
        )
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        let eventID = await store.recordReview(
            card: staleCard,
            rating: .again,
            duration: nil,
            reviewedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertNotNil(eventID)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(store.libraryCards.map(\.id), [canonicalID])
        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.id, canonicalID)
        XCTAssertFalse(record.isInActiveSession)
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(persisted.id, canonicalID)
        XCTAssertEqual(persisted.promptText, "現在のローカル内容")
        XCTAssertNotEqual(persisted.state, canonicalCard.state)
        let review = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                .first(where: { $0.kind == "review" })
        )
        XCTAssertEqual(review.resourceID, canonicalID)
        let pendingReview = try StorageCodec.decoder.decode(
            PendingReviewPayload.self,
            from: review.payload
        )
        XCTAssertEqual(pendingReview.event.cardID, canonicalID)
        XCTAssertEqual(pendingReview.cardBefore.id, canonicalID)
        XCTAssertEqual(store.sessionFailureCount, 1)

        try await store.undoReview(
            eventID: try XCTUnwrap(eventID),
            cardBefore: staleCard
        )

        XCTAssertEqual(store.sessionFailureCount, 0)
        XCTAssertEqual(store.cards.map(\.id), [canonicalID])
        XCTAssertEqual(store.cards.first?.promptText, "現在のローカル内容")
    }

    @MainActor
    func testPendingReviewFiltersCaseCanonicalizedCardsFromEverySession() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000001R",
            expression: "保留"
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
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        await store.recordReview(card: card, rating: .good, duration: nil)

        let serverCard = makeCard(
            id: card.id.lowercased(),
            expression: "保留"
        )
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 0,
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
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            XCTAssertTrue(
                ["/api/study/session/start", "/api/study/lessons/start"]
                    .contains(path)
            )
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
        let relaunchedStore = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        try await relaunchedStore.refreshSession()
        XCTAssertTrue(relaunchedStore.cards.isEmpty)

        try await relaunchedStore.refreshLessons()
        XCTAssertTrue(relaunchedStore.cards.isEmpty)
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
            expression: "戻す",
            masteryLevel: "guru"
        )
        let localRecord = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        localRecord.locallyUpdatedAt = Date(timeIntervalSince1970: 1_000)
        container.mainContext.insert(localRecord)
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
        let persisted = try persistedCard(in: container)
        XCTAssertEqual(persisted.state, card.state)
        XCTAssertEqual(persisted.masteryLevel, "guru")
        XCTAssertEqual(store.cards.first?.masteryLevel, "guru")
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
            newCardsAvailableToday: 0,
            learningReadiness: StudyLearningReadiness(
                recommendation: "ready",
                readinessLevel: "ready",
                sampleSize: 40,
                sufficientData: true,
                recentRecall: 0.95,
                targetRecall: 0.9,
                dueBacklog: 0,
                apprenticeCount: 0,
                projectedSevenDayReviews: 28,
                timedReviewSampleSize: 40,
                medianReviewDurationSeconds: 900,
                projectedDailyReviewMinutes: 60,
                reviewTimeBudgetMinutes: nil,
                reviewTimeHeadroomMinutes: nil,
                suggestedBatchSize: 5
            )
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
            if path == "/api/study/settings" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(
                        #"{"newCardsPerDay":10,"lessonBatchSize":5,"reviewTimeBudgetMinutes":150}"#.utf8
                    )
                )
            }
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

        await store.refreshStudySettings()

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
            [
                "/api/study/settings",
                "/api/card-review-events/batch",
                "/api/study/reviews/undo",
            ]
        )
        XCTAssertEqual(undoEventIDs.values, [eventID.lowercased()])
        XCTAssertEqual(store.cards.map(\.id), [card.id])
        XCTAssertEqual(store.sessionCounts.reviewRemaining, 1)
        XCTAssertEqual(store.overview?.reviewTimeBudgetMinutes, 150)
        XCTAssertEqual(store.overview?.learningReadiness?.reviewTimeBudgetMinutes, 150)
        XCTAssertEqual(store.overview?.learningReadiness?.reviewTimeHeadroomMinutes, 90)
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
            id: "local-card-id",
            syncId: "server-card-id",
            expression: "削除済み"
        )
        container.mainContext.insert(
            PendingMutation(
                kind: "cardDelete",
                userID: 1,
                resourceID: "SERVER-CARD-ID",
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
            queueState: "review",
            masteryLevel: "guru"
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
            dueAt: Date(timeIntervalSince1970: 2_000),
            masteryLevel: "apprentice"
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
        XCTAssertEqual(restoredCard.masteryLevel, "apprentice")
        XCTAssertEqual(restoredCard.state, serverCard.state)
        XCTAssertEqual(store.cards.first, restoredCard)
    }

    @MainActor
    func testSuspendCardPostsActionAndRemovesItFromTheActiveSession() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let dueAt = Date(timeIntervalSince1970: 1_800_000_000)
        let card = makeCard(
            id: "01J00000000000000000000S1",
            expression: "Suspend me",
            queueState: "review",
            dueAt: dueAt
        )
        try insertLocalCard(card, userID: 1, container: container)
        let suspended = replacingSchedule(card, queueState: "suspended", dueAt: dueAt)
        let responseData = try StorageCodec.encoder.encode(StudyCardActionResponse(
            card: suspended,
            overview: actionOverview(dueCount: 0, reviewCount: 0)
        ))
        let cardID = card.id
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/cards/\(cardID)/actions")
            XCTAssertEqual(request.httpMethod, "POST")
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            )
            XCTAssertEqual(payload["action"] as? String, "suspend")
            XCTAssertNil(payload["mode"])
            XCTAssertNil(payload["dueAt"])
            XCTAssertNil(payload["timeZone"])
            return Self.response(data: responseData)
        }
        let store = makeStore(container: container, client: client, userID: 1)

        let updated = try await store.performCardAction(.suspend, on: card)

        XCTAssertEqual(updated.state.queueState, "suspended")
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(store.libraryCards.first?.state.queueState, "suspended")
        XCTAssertEqual(store.overview?.dueCount, 0)
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        XCTAssertFalse(record.isInActiveSession)
    }

    @MainActor
    func testForgetCardResetsItToNewAndPersistsTheServerSchedule() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000F1",
            expression: "Forget me",
            queueState: "review",
            dueAt: .now,
            scheduler: .object(["state": .number(2), "reps": .number(12)])
        )
        try insertLocalCard(card, userID: 1, container: container)
        let forgotten = replacingSchedule(
            card,
            queueState: "new",
            dueAt: nil,
            scheduler: .object(["state": .number(0), "reps": .number(0)])
        )
        let responseData = try StorageCodec.encoder.encode(StudyCardActionResponse(
            card: forgotten,
            overview: actionOverview(dueCount: 0, newCount: 1, reviewCount: 0)
        ))
        let client = makeClient { request in
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            )
            XCTAssertEqual(payload["action"] as? String, "forget")
            return Self.response(data: responseData)
        }
        let store = makeStore(container: container, client: client, userID: 1)

        let updated = try await store.performCardAction(.forget, on: card)

        XCTAssertEqual(updated.state.queueState, "new")
        XCTAssertNil(updated.state.dueAt)
        XCTAssertEqual(updated.state.scheduler?["reps"], .number(0))
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(store.overview?.newCount, 1)
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(persisted.state, updated.state)
    }

    @MainActor
    func testSetDueSendsTomorrowTimezoneAndCustomDatePayloads() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000D1",
            expression: "Set me due",
            queueState: "review",
            dueAt: .now
        )
        try insertLocalCard(card, userID: 1, container: container)
        let futureDueAt = Date(timeIntervalSince1970: 1_800_000_000)
        let rescheduled = replacingSchedule(card, queueState: "review", dueAt: futureDueAt)
        let responseData = try StorageCodec.encoder.encode(StudyCardActionResponse(
            card: rescheduled,
            overview: actionOverview(dueCount: 0, reviewCount: 1)
        ))
        let bodies = LockedRequestBodies()
        let client = makeClient { request in
            bodies.append(try requestBody(request))
            return Self.response(data: responseData)
        }
        let store = makeStore(container: container, client: client, userID: 1)
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))

        _ = try await store.performCardAction(
            .setDue,
            on: card,
            mode: .tomorrow,
            timeZone: newYork
        )
        _ = try await store.performCardAction(
            .setDue,
            on: rescheduled,
            mode: .customDate,
            dueAt: futureDueAt,
            timeZone: newYork
        )

        XCTAssertEqual(bodies.values.count, 2)
        let tomorrow = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodies.values[0]) as? [String: Any]
        )
        XCTAssertEqual(tomorrow["action"] as? String, "set_due")
        XCTAssertEqual(tomorrow["mode"] as? String, "custom_date")
        XCTAssertNil(tomorrow["timeZone"])
        let tomorrowDueAt = try XCTUnwrap(tomorrow["dueAt"] as? String)
        let parsedTomorrowDueAt = try XCTUnwrap(ISO8601Milliseconds.date(from: tomorrowDueAt))
        var newYorkCalendar = Calendar(identifier: .gregorian)
        newYorkCalendar.timeZone = newYork
        XCTAssertEqual(newYorkCalendar.component(.hour, from: parsedTomorrowDueAt), 9)
        XCTAssertEqual(
            newYorkCalendar.dateComponents(
                [.day],
                from: newYorkCalendar.startOfDay(for: .now),
                to: newYorkCalendar.startOfDay(for: parsedTomorrowDueAt)
            ).day,
            1
        )
        let custom = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodies.values[1]) as? [String: Any]
        )
        XCTAssertEqual(custom["mode"] as? String, "custom_date")
        XCTAssertNotNil(custom["dueAt"] as? String)
        XCTAssertNil(custom["timeZone"])
        XCTAssertTrue(store.cards.isEmpty)
    }

    @MainActor
    func testSetDueNowKeepsAnEligibleCardInTheActiveSession() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000N1",
            expression: "Due now",
            queueState: "review",
            dueAt: .now
        )
        try insertLocalCard(card, userID: 1, container: container)
        let dueNow = replacingSchedule(
            card,
            queueState: "review",
            dueAt: Date(timeIntervalSinceNow: -1)
        )
        let responseData = try StorageCodec.encoder.encode(StudyCardActionResponse(
            card: dueNow,
            overview: actionOverview(dueCount: 1, reviewCount: 1)
        ))
        let client = makeClient { request in
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            )
            XCTAssertEqual(payload["action"] as? String, "set_due")
            XCTAssertEqual(payload["mode"] as? String, "custom_date")
            XCTAssertNotNil(payload["dueAt"] as? String)
            XCTAssertNil(payload["timeZone"])
            return Self.response(data: responseData)
        }
        let store = makeStore(container: container, client: client, userID: 1)

        let updated = try await store.performCardAction(.setDue, on: card, mode: .now)

        XCTAssertEqual(store.cards, [updated])
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        XCTAssertTrue(record.isInActiveSession)
    }

    @MainActor
    func testCardActionPreservesAnEditQueuedWhileTheRequestIsInFlight() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000P1",
            expression: "Original prompt",
            queueState: "review",
            dueAt: .now
        )
        try insertLocalCard(card, userID: 1, container: container)
        let serverCard = makeCard(
            id: card.id,
            expression: "Stale server prompt",
            queueState: "suspended",
            dueAt: card.state.dueAt
        )
        let responseData = try StorageCodec.encoder.encode(StudyCardActionResponse(
            card: serverCard,
            overview: actionOverview(dueCount: 0, reviewCount: 0)
        ))
        let deferredAction = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            if request.url?.path.hasSuffix("/actions") == true {
                deferredAction.hold(completion)
            } else if request.httpMethod == "PATCH" {
                completion(.failure(URLError(.notConnectedToInternet)))
            } else {
                completion(.failure(URLError(.badURL)))
            }
        }
        let store = makeStore(container: container, client: client, userID: 1)
        let actionTask = Task {
            try await store.performCardAction(.suspend, on: card)
        }
        await deferredAction.waitUntilPending()

        try await store.updateCard(
            card,
            prompt: "Local pending edit",
            reading: "",
            answer: "Local answer"
        )
        deferredAction.succeed(with: Self.response(data: responseData))
        let updated = try await actionTask.value

        XCTAssertEqual(updated.promptText, "Local pending edit")
        XCTAssertEqual(updated.answerText, "Local answer")
        XCTAssertEqual(updated.state.queueState, "suspended")
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        XCTAssertNotNil(record.locallyUpdatedAt)
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(persisted.promptText, "Local pending edit")
        XCTAssertEqual(persisted.state.queueState, "suspended")
        let pendingUpdates = try container.mainContext.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate { $0.kind == "cardUpdate" }
            )
        )
        XCTAssertEqual(pendingUpdates.count, 1)
    }

    @MainActor
    func testCardActionPersistsOfflineAndReplaysAfterStoreRestart() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000Q1",
            expression: "Queue offline",
            queueState: "review",
            dueAt: .now
        )
        try insertLocalCard(card, userID: 1, container: container)
        let offlineClient = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        let firstStore = makeStore(container: container, client: offlineClient, userID: 1)

        let optimistic = try await firstStore.performCardAction(.suspend, on: card)

        XCTAssertEqual(optimistic.state.queueState, "suspended")
        XCTAssertTrue(firstStore.cards.isEmpty)
        var pending = try container.mainContext.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate { $0.kind == "cardAction" }
            )
        )
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.attemptCount, 1)
        firstStore.deactivate()

        let serverCard = replacingSchedule(
            card,
            queueState: "suspended",
            dueAt: card.state.dueAt
        )
        let responseData = try StorageCodec.encoder.encode(StudyCardActionResponse(
            card: serverCard,
            overview: actionOverview(dueCount: 0, reviewCount: 0)
        ))
        let paths = LockedRequestPaths()
        let onlineClient = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.hasSuffix("/actions") {
                return Self.response(data: responseData)
            }
            throw URLError(.notConnectedToInternet)
        }
        let restoredStore = makeStore(container: container, client: onlineClient, userID: 1)
        XCTAssertEqual(restoredStore.libraryCards.first?.state.queueState, "suspended")

        await restoredStore.synchronize()

        XCTAssertTrue(paths.values.contains { $0.hasSuffix("/actions") })
        pending = try container.mainContext.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate { $0.kind == "cardAction" }
            )
        )
        XCTAssertTrue(pending.isEmpty)
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        XCTAssertNil(record.locallyUpdatedAt)
        XCTAssertEqual(
            try StorageCodec.decoder.decode(StudyCard.self, from: record.payload).state.queueState,
            "suspended"
        )
    }

    @MainActor
    func testCardActionLostResponseRetriesTheSameAbsoluteDueRequest() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000Q2",
            expression: "Retry exactly",
            queueState: "review",
            dueAt: .now
        )
        try insertLocalCard(card, userID: 1, container: container)
        let dueAt = Date(timeIntervalSince1970: 1_800_000_000)
        let serverCard = replacingSchedule(card, queueState: "review", dueAt: dueAt)
        let responseData = try StorageCodec.encoder.encode(StudyCardActionResponse(
            card: serverCard,
            overview: actionOverview(dueCount: 0, reviewCount: 1)
        ))
        let attempts = LockedCounter()
        let bodies = LockedRequestBodies()
        let client = makeClient { request in
            guard request.url?.path.hasSuffix("/actions") == true else {
                throw URLError(.notConnectedToInternet)
            }
            bodies.append(try requestBody(request))
            if attempts.next() == 1 {
                throw URLError(.timedOut)
            }
            return Self.response(data: responseData)
        }
        let store = makeStore(container: container, client: client, userID: 1)

        _ = try await store.performCardAction(
            .setDue,
            on: card,
            mode: .customDate,
            dueAt: dueAt
        )
        await store.synchronize()

        XCTAssertEqual(bodies.values.count, 2)
        XCTAssertEqual(
            try StorageCodec.decoder.decode(
                StudyCardActionRequest.self,
                from: bodies.values[0]
            ),
            try StorageCodec.decoder.decode(
                StudyCardActionRequest.self,
                from: bodies.values[1]
            )
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodies.values[0]) as? [String: Any]
        )
        XCTAssertEqual(payload["mode"] as? String, "custom_date")
        XCTAssertEqual(
            ISO8601Milliseconds.date(from: try XCTUnwrap(payload["dueAt"] as? String)),
            dueAt
        )
        XCTAssertEqual(
            try container.mainContext.fetchCount(
                FetchDescriptor<PendingMutation>(
                    predicate: #Predicate { $0.kind == "cardAction" }
                )
            ),
            0
        )
    }

    @MainActor
    func testPendingReviewDrainsBeforeLaterQueuedCardAction() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000Q3",
            expression: "Keep order",
            queueState: "review",
            dueAt: .now
        )
        try insertLocalCard(card, userID: 1, container: container)
        let reviewEvent = ReviewBatchRequest.Event(
            id: "01J00000000000000000000E1",
            cardID: card.reviewCardID,
            rating: .good,
            reviewedAt: .now,
            durationMilliseconds: 900,
            clientEventID: "01J00000000000000000000E1",
            deviceID: "test-device",
            clientCreatedAt: .now
        )
        container.mainContext.insert(PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: card.id,
            payload: try StorageCodec.encoder.encode(PendingReviewPayload(
                event: reviewEvent,
                cardBefore: PendingReviewCardState(card: card)
            ))
        ))
        try container.mainContext.save()
        let serverCard = replacingSchedule(
            card,
            queueState: "suspended",
            dueAt: card.state.dueAt
        )
        let responseData = try StorageCodec.encoder.encode(StudyCardActionResponse(
            card: serverCard,
            overview: actionOverview(dueCount: 0, reviewCount: 0)
        ))
        let online = LockedCounter()
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if online.current == 0 {
                throw URLError(.notConnectedToInternet)
            }
            if path == "/api/card-review-events/batch" {
                return Self.response(data: Data())
            }
            if path.hasSuffix("/actions") {
                return Self.response(data: responseData)
            }
            throw URLError(.notConnectedToInternet)
        }
        let store = makeStore(container: container, client: client, userID: 1)

        _ = try await store.performCardAction(.suspend, on: card)
        XCTAssertFalse(paths.values.contains { $0.hasSuffix("/actions") })
        _ = online.next()
        await store.synchronize()

        let deliveredWrites = paths.values.filter {
            $0 == "/api/card-review-events/batch" || $0.hasSuffix("/actions")
        }
        XCTAssertEqual(Array(deliveredWrites.suffix(2)), [
            "/api/card-review-events/batch",
            "/api/study/cards/\(card.reviewCardID)/actions",
        ])
    }

    @MainActor
    func testReviewAfterOfflineCardActionIsQueuedAndDeliveredAfterTheAction() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000Q6",
            expression: "Grade after action",
            queueState: "suspended",
            dueAt: nil,
            scheduler: .object(["state": .number(2)])
        )
        try insertLocalCard(card, userID: 1, container: container)
        let unsuspended = replacingSchedule(
            card,
            queueState: "review",
            dueAt: .now
        )
        let actionResponseData = try StorageCodec.encoder.encode(
            StudyCardActionResponse(
                card: unsuspended,
                overview: actionOverview(dueCount: 1, reviewCount: 1)
            )
        )
        let online = LockedCounter()
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            guard online.current > 0 else {
                throw URLError(.notConnectedToInternet)
            }
            if path.hasSuffix("/actions") {
                return Self.response(data: actionResponseData)
            }
            if path == "/api/card-review-events/batch" {
                return Self.response(data: Data())
            }
            throw URLError(.notConnectedToInternet)
        }
        let store = makeStore(container: container, client: client, userID: 1)

        let optimisticAction = try await store.performCardAction(.unsuspend, on: card)
        let eventID = await store.recordReview(
            card: optimisticAction,
            rating: .good,
            duration: .seconds(1)
        )

        XCTAssertNotNil(eventID)
        XCTAssertTrue(store.cards.isEmpty)
        let queuedKinds = try container.mainContext.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.kind == "cardAction" || $0.kind == "review"
                },
                sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
            )
        ).map(\.kind)
        XCTAssertEqual(queuedKinds, ["cardAction", "review"])

        _ = online.next()
        await store.synchronize()

        let deliveredWrites = paths.values.filter {
            $0.hasSuffix("/actions") || $0 == "/api/card-review-events/batch"
        }
        XCTAssertEqual(Array(deliveredWrites.suffix(2)), [
            "/api/study/cards/\(card.reviewCardID)/actions",
            "/api/card-review-events/batch",
        ])
        XCTAssertEqual(
            try container.mainContext.fetchCount(
                FetchDescriptor<PendingMutation>(
                    predicate: #Predicate {
                        $0.kind == "cardAction" || $0.kind == "review"
                    }
                )
            ),
            0
        )
    }

    @MainActor
    func testEarlierEditAcknowledgementPreservesLaterQueuedActionProjection() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000Q4",
            expression: "Original",
            queueState: "review",
            dueAt: .now
        )
        try insertLocalCard(card, userID: 1, container: container)
        let editedServerCard = makeCard(
            id: card.id,
            expression: "Edited",
            queueState: "review",
            dueAt: card.state.dueAt
        )
        let editedServerData = try StorageCodec.encoder.encode(editedServerCard)
        let phase = LockedCounter()
        let client = makeClient { request in
            guard phase.current > 0 else {
                throw URLError(.notConnectedToInternet)
            }
            if request.httpMethod == "PATCH" {
                return Self.response(data: editedServerData)
            }
            throw URLError(.notConnectedToInternet)
        }
        let store = makeStore(container: container, client: client, userID: 1)
        try await store.updateCard(
            card,
            prompt: "Edited",
            reading: "",
            answer: "meaning"
        )
        _ = phase.next()

        let optimistic = try await store.performCardAction(.suspend, on: card)

        XCTAssertEqual(optimistic.promptText, "Edited")
        XCTAssertEqual(optimistic.state.queueState, "suspended")
        XCTAssertEqual(try persistedCard(in: container).state.queueState, "suspended")
        let pendingKinds = try container.mainContext.fetch(
            FetchDescriptor<PendingMutation>()
        ).map(\.kind)
        XCTAssertEqual(pendingKinds, ["cardAction"])
    }

    @MainActor
    func testMultipleOfflineCardActionsReplayInOrderAndKeepNewestProjection() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000Q5",
            expression: "Ordered actions",
            queueState: "review",
            dueAt: .now
        )
        try insertLocalCard(card, userID: 1, container: container)
        let futureDueAt = Date(timeIntervalSince1970: 1_800_000_000)
        let suspended = replacingSchedule(
            card,
            queueState: "suspended",
            dueAt: card.state.dueAt
        )
        let rescheduled = replacingSchedule(
            card,
            queueState: "review",
            dueAt: futureDueAt
        )
        let suspendedResponseData = try StorageCodec.encoder.encode(
            StudyCardActionResponse(
                card: suspended,
                overview: actionOverview(dueCount: 0, reviewCount: 0)
            )
        )
        let rescheduledResponseData = try StorageCodec.encoder.encode(
            StudyCardActionResponse(
                card: rescheduled,
                overview: actionOverview(dueCount: 0, reviewCount: 1)
            )
        )
        let online = LockedCounter()
        let deliveredBodies = LockedRequestBodies()
        let client = makeClient { request in
            guard request.url?.path.hasSuffix("/actions") == true,
                  online.current > 0
            else {
                throw URLError(.notConnectedToInternet)
            }
            let body = try requestBody(request)
            deliveredBodies.append(body)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            return Self.response(data: payload["action"] as? String == "suspend"
                ? suspendedResponseData
                : rescheduledResponseData)
        }
        let store = makeStore(container: container, client: client, userID: 1)

        let firstProjection = try await store.performCardAction(.suspend, on: card)
        let latestProjection = try await store.performCardAction(
            .setDue,
            on: firstProjection,
            mode: .customDate,
            dueAt: futureDueAt
        )
        XCTAssertEqual(latestProjection.state.queueState, "review")
        XCTAssertEqual(latestProjection.state.dueAt, futureDueAt)
        _ = online.next()

        await store.synchronize()

        let deliveredActions = try deliveredBodies.values.map {
            try StorageCodec.decoder.decode(StudyCardActionRequest.self, from: $0).action
        }
        XCTAssertEqual(deliveredActions, [.suspend, .setDue])
        XCTAssertEqual(try persistedCard(in: container).state.dueAt, futureDueAt)
        XCTAssertEqual(
            try container.mainContext.fetchCount(
                FetchDescriptor<PendingMutation>(
                    predicate: #Predicate { $0.kind == "cardAction" }
                )
            ),
            0
        )
    }

    @MainActor
    func testSetDueCustomDateUsesNineAMInTheSelectedCalendar() throws {
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let selected = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 27, hour: 16, minute: 45)
        ))

        let dueAt = StudySetDueView.localNineAM(on: selected, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: dueAt)

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 27)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 0)
    }

    @MainActor
    private func insertLocalCard(
        _ card: StudyCard,
        userID: Int,
        container: ModelContainer
    ) throws {
        container.mainContext.insert(LocalCardRecord(
            card: card,
            userID: userID,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        ))
        try container.mainContext.save()
    }

    @MainActor
    private func makeStore(
        container: ModelContainer,
        client: APIClient,
        userID: Int
    ) -> StudyStore {
        StudyStore(
            initialUserID: userID,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: userID,
                api: client,
                context: container.mainContext
            )
        )
    }

    @MainActor
    private func actionOverview(
        dueCount: Int,
        newCount: Int = 0,
        reviewCount: Int
    ) -> StudyOverview {
        StudyOverview(
            dueCount: dueCount,
            newCount: newCount,
            reviewCount: reviewCount,
            totalCards: 1,
            newCardsPerDay: 20,
            newCardsAvailableToday: newCount
        )
    }

    @MainActor
    private func replacingSchedule(
        _ card: StudyCard,
        queueState: String,
        dueAt: Date?,
        scheduler: JSONValue? = nil
    ) -> StudyCard {
        StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer,
            state: .init(
                dueAt: dueAt,
                introducedAt: card.state.introducedAt,
                failedAt: queueState == "new" ? nil : card.state.failedAt,
                queueState: queueState,
                scheduler: scheduler ?? card.state.scheduler,
                source: card.state.source
            ),
            answerAudioSource: card.answerAudioSource,
            masteryLevel: card.masteryLevel,
            createdAt: card.createdAt,
            updatedAt: .now
        )
    }

    private static func response(
        statusCode: Int = 200,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: URL(string: "https://learning-os.example")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            data
        )
    }

    @MainActor
    func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    func makeDeferredClient(
        handler: @escaping MockURLProtocol.DeferredHandler
    ) -> APIClient {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    func makeClient(protocolClass: AnyClass) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    func makeDelayedPitchClient(
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
    func makeDelayedAnswerAudioClient(
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
    func makeDelayedAnswerAudioDownloadClient(
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
    private func makeManualDraft(
        id: String,
        expression: String
    ) -> StudyManualCardDraft {
        StudyManualCardDraft(
            id: id,
            status: "ready",
            committedCardId: nil,
            creationKind: .textRecognition,
            cardType: "recognition",
            prompt: .object(["cueText": .string(expression)]),
            answer: .object(["meaning": .string("meaning")]),
            imagePlacement: .none,
            imagePrompt: nil,
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil,
            errorMessage: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }

    @MainActor
    func makeCard(
        id: String,
        syncId: String? = nil,
        expression: String,
        mediaURL: String? = nil,
        queueState: String = "review",
        dueAt: Date? = nil,
        scheduler: JSONValue? = nil,
        masteryLevel: String? = nil
    ) -> StudyCard {
        var prompt: [String: JSONValue] = ["cueText": .string(expression)]
        if let mediaURL {
            prompt["cueAudio"] = .object(["url": .string(mediaURL)])
        }
        return StudyCard(
            id: id,
            syncId: syncId,
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
            masteryLevel: masteryLevel,
            createdAt: .now,
            updatedAt: .now
        )
    }

    @MainActor
    func sessionResponseData(
        cards: [StudyCard],
        lessonBatchSize: Int = 5
    ) throws -> Data {
        let session = StudySession(
            overview: StudyOverview(
                dueCount: cards.filter { $0.state.queueState != "new" }.count,
                newCount: cards.filter { $0.state.queueState == "new" }.count,
                reviewCount: cards.filter { $0.state.queueState != "new" }.count,
                newCardsPerDay: 20,
                newCardsAvailableToday: cards.filter { $0.state.queueState == "new" }.count,
                lessonBatchSize: lessonBatchSize
            ),
            cards: cards
        )
        let object = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        return try JSONSerialization.data(withJSONObject: ["data": object])
    }

    @MainActor
    func cardWithResolvedPitchAccent(_ card: StudyCard) -> StudyCard {
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
    func persistedCard(
        in container: ModelContainer
    ) throws -> StudyCard {
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        return try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
    }

    @MainActor
    func waitUntil(
        _ condition: @escaping @Sendable () -> Bool
    ) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor
    func makeQueueItem(id: String, position: Int) -> StudyNewCardQueueItem {
        StudyNewCardQueueItem(
            id: id,
            noteId: id,
            cardType: "recognition",
            displayText: id,
            meaning: "meaning",
            queuePosition: position,
            createdAt: .now,
            updatedAt: .now
        )
    }

    @MainActor
    func queuePage(
        items: [StudyNewCardQueueItem],
        total: Int,
        nextCursor: String?
    ) throws -> Data {
        try StorageCodec.encoder.encode(
            StudyNewCardQueueResponse(
                items: items,
                total: total,
                limit: 100,
                nextCursor: nextCursor
            )
        )
    }

    @MainActor
    func makeStore(protocolClass: AnyClass) throws -> StudyStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        let container = try Persistence.makeContainer(inMemory: true)
        return StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
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

final class LockedRequestBodies: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var values: [Data] {
        lock.withLock { storage }
    }

    func append(_ body: Data) {
        lock.withLock { storage.append(body) }
    }
}

final class OverlappingStudySessionURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var firstReviewData = Data()
    nonisolated(unsafe) private static var secondReviewData = Data()
    nonisolated(unsafe) private static var lessonData = Data()
    nonisolated(unsafe) private static var pendingFirstReview: OverlappingStudySessionURLProtocol?
    nonisolated(unsafe) private static var pendingLesson: OverlappingStudySessionURLProtocol?
    nonisolated(unsafe) private static var reviewRequestCount = 0
    nonisolated(unsafe) private static var holdsLesson = false

    static var hasPendingFirstReview: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingFirstReview != nil
    }

    static var hasPendingLesson: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingLesson != nil
    }

    static func configure(
        firstReview: Data,
        secondReview: Data,
        lesson: Data,
        holdLesson: Bool = false
    ) {
        lock.lock()
        firstReviewData = firstReview
        secondReviewData = secondReview
        lessonData = lesson
        pendingFirstReview = nil
        pendingLesson = nil
        reviewRequestCount = 0
        holdsLesson = holdLesson
        lock.unlock()
    }

    static func releaseFirstReview() {
        lock.lock()
        let request = pendingFirstReview
        let data = firstReviewData
        pendingFirstReview = nil
        lock.unlock()
        request?.respond(with: data)
    }

    static func releaseLesson() {
        lock.lock()
        let request = pendingLesson
        let data = lessonData
        pendingLesson = nil
        lock.unlock()
        request?.respond(with: data)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        if request.url?.path == "/api/study/lessons/start" {
            if Self.holdsLesson {
                Self.pendingLesson = self
                Self.lock.unlock()
                return
            }
            let data = Self.lessonData
            Self.lock.unlock()
            respond(with: data)
            return
        }
        Self.reviewRequestCount += 1
        if Self.reviewRequestCount == 1 {
            Self.pendingFirstReview = self
            Self.lock.unlock()
            return
        }
        let data = Self.secondReviewData
        Self.lock.unlock()
        respond(with: data)
    }

    override func stopLoading() {}

    private func respond(with data: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class OutOfOrderCardListURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var firstResponseData = Data()
    nonisolated(unsafe) private static var secondResponseData = Data()
    nonisolated(unsafe) private static var pendingFirstRequest: OutOfOrderCardListURLProtocol?

    static var hasPendingFirstRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingFirstRequest != nil
    }

    static func configure(first: Data, second: Data) {
        lock.lock()
        firstResponseData = first
        secondResponseData = second
        pendingFirstRequest = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.query?.contains("q=first") == true {
            Self.lock.lock()
            Self.pendingFirstRequest = self
            Self.lock.unlock()
            return
        }

        respond(with: Self.secondResponseData)
        Self.lock.lock()
        let firstRequest = Self.pendingFirstRequest
        Self.pendingFirstRequest = nil
        Self.lock.unlock()
        firstRequest?.respond(with: Self.firstResponseData)
    }

    override func stopLoading() {}

    private func respond(with data: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class OverlappingCardListPageURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var initialPage = Data()
    nonisolated(unsafe) private static var refreshedPage = Data()
    nonisolated(unsafe) private static var staleNextPage = Data()
    nonisolated(unsafe) private static var servedInitialPage = false
    nonisolated(unsafe) private static var pendingNextPage: OverlappingCardListPageURLProtocol?

    static var hasPendingNextPage: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingNextPage != nil
    }

    static func configure(initialPage: Data, refreshedPage: Data, staleNextPage: Data) {
        lock.lock()
        self.initialPage = initialPage
        self.refreshedPage = refreshedPage
        self.staleNextPage = staleNextPage
        servedInitialPage = false
        pendingNextPage = nil
        lock.unlock()
    }

    static func releasePendingNextPage() {
        lock.lock()
        let request = pendingNextPage
        pendingNextPage = nil
        let data = staleNextPage
        lock.unlock()
        request?.respond(with: data)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.query?.contains("cursor=") == true {
            Self.lock.lock()
            Self.pendingNextPage = self
            Self.lock.unlock()
            return
        }

        Self.lock.lock()
        let data = Self.servedInitialPage ? Self.refreshedPage : Self.initialPage
        Self.servedInitialPage = true
        Self.lock.unlock()
        respond(with: data)
    }

    override func stopLoading() {}

    private func respond(with data: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class OverlappingQueueReorderURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var initialPage = Data()
    nonisolated(unsafe) private static var refreshedPage = Data()
    nonisolated(unsafe) private static var reorderPage = Data()
    nonisolated(unsafe) private static var reorderStatus = 200
    nonisolated(unsafe) private static var nextPage = Data()
    nonisolated(unsafe) private static var nextPageStatus = 200
    nonisolated(unsafe) private static var servedInitialPage = false
    nonisolated(unsafe) private static var holdSecondRefresh = false
    nonisolated(unsafe) private static var pendingRefresh: OverlappingQueueReorderURLProtocol?
    nonisolated(unsafe) private static var pendingLoadMore: OverlappingQueueReorderURLProtocol?
    nonisolated(unsafe) private static var pendingReorder: OverlappingQueueReorderURLProtocol?

    static var hasPendingRefresh: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingRefresh != nil
    }

    static var hasPendingReorder: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingReorder != nil
    }

    static var hasPendingLoadMore: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingLoadMore != nil
    }

    static func configure(
        initialPage: Data,
        refreshedPage: Data,
        reorderPage: Data,
        reorderStatus: Int,
        holdSecondRefresh: Bool = false,
        nextPage: Data = Data(),
        nextPageStatus: Int = 200
    ) {
        lock.lock()
        self.initialPage = initialPage
        self.refreshedPage = refreshedPage
        self.reorderPage = reorderPage
        self.reorderStatus = reorderStatus
        self.holdSecondRefresh = holdSecondRefresh
        self.nextPage = nextPage
        self.nextPageStatus = nextPageStatus
        servedInitialPage = false
        pendingRefresh = nil
        pendingLoadMore = nil
        pendingReorder = nil
        lock.unlock()
    }

    static func releasePendingRefresh() {
        lock.lock()
        let request = pendingRefresh
        pendingRefresh = nil
        let data = refreshedPage
        lock.unlock()
        request?.respond(with: data, statusCode: 200)
    }

    static func releasePendingReorder() {
        lock.lock()
        let request = pendingReorder
        pendingReorder = nil
        let data = reorderPage
        let status = reorderStatus
        lock.unlock()
        request?.respond(with: data, statusCode: status)
    }

    static func releasePendingLoadMore() {
        lock.lock()
        let request = pendingLoadMore
        pendingLoadMore = nil
        let data = nextPage
        let status = nextPageStatus
        lock.unlock()
        request?.respond(with: data, statusCode: status)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.path == "/api/study/new-queue/reorder" {
            Self.lock.lock()
            Self.pendingReorder = self
            Self.lock.unlock()
            return
        }

        if request.url?.query?.contains("cursor=") == true {
            Self.lock.lock()
            Self.pendingLoadMore = self
            Self.lock.unlock()
            return
        }

        Self.lock.lock()
        if Self.servedInitialPage, Self.holdSecondRefresh {
            Self.pendingRefresh = self
            Self.lock.unlock()
            return
        }
        let data = Self.servedInitialPage ? Self.refreshedPage : Self.initialPage
        Self.servedInitialPage = true
        Self.lock.unlock()
        respond(with: data, statusCode: 200)
    }

    override func stopLoading() {}

    private func respond(with data: Data, statusCode: Int) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
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

final class LockedDeferredResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: MockURLProtocol.DeferredCompletion?
    private var pendingWaiters: [CheckedContinuation<Void, Never>] = []

    var hasPendingResponse: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completion != nil
    }

    func hold(_ completion: @escaping MockURLProtocol.DeferredCompletion) {
        lock.lock()
        self.completion = completion
        let pendingWaiters = pendingWaiters
        self.pendingWaiters = []
        lock.unlock()
        pendingWaiters.forEach { $0.resume() }
    }

    func waitUntilPending() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if completion != nil {
                lock.unlock()
                continuation.resume()
            } else {
                pendingWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func succeed(with response: (HTTPURLResponse, Data)) {
        lock.lock()
        let completion = completion
        self.completion = nil
        lock.unlock()
        completion?(.success(response))
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
