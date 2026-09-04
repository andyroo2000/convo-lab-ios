import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

private struct AudioCommitModels {
    let audio: JSONValue
    let serverDraft: StudyManualCardDraft
    let card: StudyCard
}

private struct RejectedDraftRetryFixture {
    let draftID: String
    let clientCardID: String
    let serverDraft: StudyManualCardDraft
    let mutation: PendingMutation
    let commitIDs: LockedRequestPaths
    let patchedExpressions: LockedRequestPaths
    let script: DraftCommitResponseScript
}

extension StudyStoreTests {
    @MainActor
    func testAudioRecognitionDraftCommitEmbedsPromptAudioAndPersistsCanonicalCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let models = makeAudioCommitModels()
        let commitIDs = LockedRequestPaths()
        let script = try makeAudioCommitScript(models: models, commitIDs: commitIDs)
        let client = makeClient { try script.response(for: $0) }
        let store = makeDraftCommitStore(container: container, client: client)
        let draft = makeAudioRecognitionDraft(
            expression: "営業の仕事は楽しいです。",
            meaning: "Sales work is fun."
        )

        let queued = try await store.queueManualDraft(
            creationKind: .audioRecognition,
            draft: draft
        )
        do {
            try await store.createCard(
                from: queued,
                draft: draft,
                previewAudio: models.audio,
                previewAudioRole: "prompt",
                previewImage: nil
            )
            XCTFail("Expected the first draft cleanup to fail")
        } catch let APIClientError.rejected(status, message) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(message, "cleanup failed")
        }
        XCTAssertEqual(store.libraryCards.map(\.id), [models.card.id])
        XCTAssertEqual(store.allCards.map(\.id), [models.card.id])
        XCTAssertFalse(store.manualDrafts.isEmpty)
        XCTAssertTrue(store.hasPendingDraftCommit(for: models.serverDraft.id))
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

        try assertAudioCommitResult(
            store: store,
            container: container,
            models: models,
            script: script,
            commitIDs: commitIDs
        )
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
        let script = DraftCommitResponseScript(routes: [
            .pathContaining(firstDraftID, response: .error(500, "first draft failed")),
            .pathSuffix("/create-card", response: .success(committedData)),
            .any(response: .noContent),
        ])
        let client = makeClient { try script.response(for: $0) }
        let store = makeDraftCommitStore(container: container, client: client)

        await assertRejectedStatus(500, expectedMessage: "first draft failed") {
            try await store.retryPendingDraftCommits()
        }

        XCTAssertEqual(
            script.requestedPaths,
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
            await assertRejectedStatus(500) {
                try await store.retryPendingDraftCommits()
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
        let serverDraft = makeDraft(
            id: draftID,
            creationKind: .audioRecognition,
            cardType: "recognition",
            expression: "再試行"
        )
        let committedCard = makeCard(
            id: clientCardID.lowercased(),
            expression: "再試行"
        )
        let serverDraftData = try StorageCodec.encoder.encode(serverDraft)
        let committedData = try StorageCodec.encoder.encode(committedCard)
        let mutation = try insertPendingDraftCommit(
            draftID: draftID,
            cardID: clientCardID,
            into: container
        )
        let commitIDs = LockedRequestPaths()
        let script = DraftCommitResponseScript(routes: [
            .pathSuffix("/create-card", responses: [
                .error(429, "try later"),
                .error(409, "Generating drafts cannot create cards yet."),
                .success(committedData),
            ]) { request in
                let body = try requestBody(request)
                let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                commitIDs.append(payload?["id"] as? String ?? "")
            },
            .method("GET", response: .success(serverDraftData)),
            .any(response: .noContent),
        ])
        let client = makeClient { try script.response(for: $0) }
        let store = makeDraftCommitStore(container: container, client: client)
        let draft = makeAudioRecognitionDraft(expression: "再試行")

        await assertRejectedStatus(429) {
            try await store.createCard(
                from: serverDraft,
                draft: draft,
                previewAudio: nil,
                previewAudioRole: nil,
                previewImage: nil
            )
        }
        XCTAssertEqual(store.draftCommitRecoveryState(for: draftID), .outcomeUnknown)
        XCTAssertNil(mutation.lastError)

        await assertRejectedStatus(409) {
            try await store.retryPendingDraftCommits()
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
        let serverDraft = makeDraft(
            id: draftID,
            committedCardId: conflictingCardID.lowercased(),
            creationKind: .audioRecognition,
            cardType: "recognition",
            expression: "競合"
        )
        let serverDraftData = try StorageCodec.encoder.encode(serverDraft)
        let mutation = try insertPendingDraftCommit(
            draftID: draftID,
            cardID: clientCardID,
            into: container
        )
        let script = DraftCommitResponseScript(routes: [
            .method("GET", response: .success(serverDraftData)),
            .any(response: .error(409, "conflict")),
        ])
        let client = makeClient { try script.response(for: $0) }
        let store = makeDraftCommitStore(container: container, client: client)

        await assertRejectedStatus(409) {
            try await store.retryPendingDraftCommits()
        }

        XCTAssertEqual(store.draftCommitRecoveryState(for: draftID), .rejected)
        XCTAssertEqual(mutation.kind, "draftCommitRejected")
        XCTAssertNotNil(mutation.lastError)
        XCTAssertEqual(store.manualDrafts.first?.committedCardId, conflictingCardID.lowercased())
    }

    @MainActor
    func testRejectedDraftCommitCanBeEditedAndRetriedWithSameID() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let fixture = try makeRejectedDraftRetryFixture(in: container)
        let script = fixture.script
        let client = makeClient { try script.response(for: $0) }
        let store = makeDraftCommitStore(container: container, client: client)
        var draft = makeProductionImageDraft(imagePrompt: "before", expression: "修正前")

        await assertRejectedStatus(422) {
            try await store.createCard(
                from: fixture.serverDraft,
                draft: draft,
                previewAudio: nil,
                previewAudioRole: nil,
                previewImage: nil
            )
        }
        XCTAssertEqual(store.draftCommitRecoveryState(for: fixture.draftID), .rejected)
        XCTAssertEqual(fixture.mutation.kind, "draftCommitRejected")
        XCTAssertNotNil(fixture.mutation.lastError)

        draft.imagePrompt = "after"
        draft.answerExpression = "修正後"
        try await store.createCard(
            from: fixture.serverDraft,
            draft: draft,
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil
        )

        XCTAssertEqual(fixture.patchedExpressions.values, ["修正後"])
        XCTAssertEqual(fixture.commitIDs.values, [fixture.clientCardID, fixture.clientCardID])
        XCTAssertFalse(store.hasPendingDraftCommit(for: fixture.draftID))
    }

    @MainActor
    func testRejectedDraftCommitCanBeDeletedSafely() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000D1"
        let serverDraft = makeDraft(
            id: draftID,
            creationKind: .audioRecognition,
            cardType: "recognition",
            expression: "削除"
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
        let store = makeDraftCommitStore(container: container, client: client)

        try await store.deleteManualDraft(serverDraft)

        XCTAssertEqual(paths.values, ["/api/study/card-drafts/\(draftID)"])
        XCTAssertFalse(store.hasPendingDraftCommit(for: draftID))
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
    }

    @MainActor
    private func makeDraftCommitStore(
        container: ModelContainer,
        client: APIClient
    ) -> StudyStore {
        StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )
    }

    @MainActor
    private func makeAudioRecognitionDraft(
        expression: String,
        meaning: String = ""
    ) -> StudyCardDraft {
        var draft = StudyCardDraft(cardType: .recognition)
        draft.isAudioLedPrompt = true
        draft.isMediaLedPrompt = true
        draft.answerExpression = expression
        draft.answerMeaning = meaning
        return draft
    }

    @MainActor
    private func makeProductionImageDraft(
        imagePrompt: String,
        expression: String
    ) -> StudyCardDraft {
        var draft = StudyCardDraft(cardType: .production)
        draft.isMediaLedPrompt = true
        draft.imagePlacement = .prompt
        draft.imagePrompt = imagePrompt
        draft.answerExpression = expression
        return draft
    }

    @MainActor
    private func makeRejectedDraftRetryFixture(
        in container: ModelContainer
    ) throws -> RejectedDraftRetryFixture {
        let draftID = "01J0000000000000000000000V1"
        let clientCardID = "01J0000000000000000000000V2"
        let now = Date.now
        let serverDraft = makeDraft(
            id: draftID,
            creationKind: .productionImage,
            cardType: "production",
            imagePlacement: .prompt,
            imagePrompt: "before",
            expression: "修正前",
            now: now
        )
        let correctedDraft = makeDraft(
            id: draftID,
            creationKind: .productionImage,
            cardType: "production",
            imagePlacement: .prompt,
            imagePrompt: "after",
            expression: "修正後",
            now: now
        )
        let committedCard = makeCard(id: clientCardID.lowercased(), expression: "修正後")
        let mutation = try insertPendingDraftCommit(
            draftID: draftID,
            cardID: clientCardID,
            into: container
        )
        let commitIDs = LockedRequestPaths()
        let patchedExpressions = LockedRequestPaths()
        let script = makeRejectedRetryScript(
            correctedData: try StorageCodec.encoder.encode(correctedDraft),
            committedData: try StorageCodec.encoder.encode(committedCard),
            commitIDs: commitIDs,
            patchedExpressions: patchedExpressions
        )
        return .init(
            draftID: draftID,
            clientCardID: clientCardID,
            serverDraft: serverDraft,
            mutation: mutation,
            commitIDs: commitIDs,
            patchedExpressions: patchedExpressions,
            script: script
        )
    }

    private func makeRejectedRetryScript(
        correctedData: Data,
        committedData: Data,
        commitIDs: LockedRequestPaths,
        patchedExpressions: LockedRequestPaths
    ) -> DraftCommitResponseScript {
        DraftCommitResponseScript(routes: [
            .method("PATCH", response: .success(correctedData)) { request in
                let payload = try Self.requestPayload(request)
                let answer = payload["answer"] as? [String: Any]
                patchedExpressions.append(answer?["expression"] as? String ?? "")
            },
            .pathSuffix("/create-card", responses: [
                .error(422, "fix the draft"),
                .success(committedData),
            ]) { request in
                let payload = try Self.requestPayload(request)
                commitIDs.append(payload["id"] as? String ?? "")
            },
            .any(response: .noContent),
        ])
    }

    @MainActor
    private func makeAudioCommitModels() -> AudioCommitModels {
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
        return .init(audio: audio, serverDraft: serverDraft, card: card)
    }

    @MainActor
    private func makeAudioCommitScript(
        models: AudioCommitModels,
        commitIDs: LockedRequestPaths
    ) throws -> DraftCommitResponseScript {
        let serverDraftData = try StorageCodec.encoder.encode(models.serverDraft)
        let committedData = try StorageCodec.encoder.encode(models.card)
        return DraftCommitResponseScript(routes: [
            .path("/api/study/card-drafts", response: .success(serverDraftData)),
            .method("PATCH", response: .success(serverDraftData)) {
                try Self.assertEnrichedAudioPayload($0)
            },
            .pathSuffix("/create-card", response: .success(committedData)) { request in
                let payload = try Self.requestPayload(request)
                XCTAssertEqual((payload["id"] as? String)?.count, 26)
                commitIDs.append(payload["id"] as? String ?? "")
            },
            .method("DELETE", responses: [
                .error(409, "cleanup failed"),
                .error(410, "draft gone"),
            ]),
            .any(response: .init(
                statusCode: 200,
                data: Data("draft-audio".utf8),
                contentType: "audio/mpeg"
            )),
        ])
    }

    private static func requestPayload(_ request: URLRequest) throws -> [String: Any] {
        let body = try requestBody(request)
        return try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
    }

    private static func assertEnrichedAudioPayload(_ request: URLRequest) throws {
        let payload = try requestPayload(request)
        let prompt = payload["prompt"] as? [String: Any]
        let answer = payload["answer"] as? [String: Any]
        XCTAssertEqual(
            (prompt?["serverEnrichment"] as? [String: Any])?["source"] as? String,
            "learning-os"
        )
        XCTAssertEqual(answer?["pitchAccent"] as? [Int], [2])
        XCTAssertEqual((prompt?["cueAudio"] as? [String: Any])?["id"] as? String, "audio-1")
        XCTAssertEqual((answer?["answerAudio"] as? [String: Any])?["id"] as? String, "audio-1")
    }

    @MainActor
    private func assertAudioCommitResult(
        store: StudyStore,
        container: ModelContainer,
        models: AudioCommitModels,
        script: DraftCommitResponseScript,
        commitIDs: LockedRequestPaths
    ) throws {
        let draftPath = "/api/study/card-drafts/\(models.serverDraft.id)"
        XCTAssertEqual(script.requestedPaths, [
            "/api/study/card-drafts",
            draftPath,
            "\(draftPath)/create-card",
            "/api/study/media/audio-1",
            draftPath,
            "\(draftPath)/create-card",
            draftPath,
        ])
        XCTAssertEqual(commitIDs.values.count, 2)
        XCTAssertEqual(commitIDs.values[0], commitIDs.values[1])
        XCTAssertTrue(store.manualDrafts.isEmpty)
        XCTAssertEqual(store.libraryCards.map(\.id), [models.card.id])
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                .allSatisfy { $0.kind != "draftCommit" }
        )
        let persisted = try persistedCard(in: container)
        XCTAssertEqual(persisted.prompt["cueAudio"], models.audio)
        XCTAssertEqual(persisted.answer["answerAudio"], models.audio)
    }

    @MainActor
    private func insertPendingDraftCommit(
        draftID: String,
        cardID: String,
        kind: String = "draftCommit",
        into container: ModelContainer
    ) throws -> PendingMutation {
        let mutation = PendingMutation(
            kind: kind,
            userID: 1,
            resourceID: draftID,
            payload: try StorageCodec.encoder.encode(
                CreateCardFromStudyManualDraftRequest(id: cardID)
            )
        )
        container.mainContext.insert(mutation)
        try container.mainContext.save()
        return mutation
    }

    @MainActor
    private func assertRejectedStatus(
        _ expectedStatus: Int,
        expectedMessage: String? = nil,
        action: () async throws -> Void
    ) async {
        do {
            try await action()
            XCTFail("Expected the request to be rejected")
        } catch let APIClientError.rejected(status, message) {
            XCTAssertEqual(status, expectedStatus)
            if let expectedMessage {
                XCTAssertEqual(message, expectedMessage)
            }
        } catch {
            XCTFail("Expected an API rejection, received \(error)")
        }
    }

    @MainActor
    private func makeDraft(
        id: String,
        committedCardId: String? = nil,
        creationKind: StudyCardCreationKind,
        cardType: String,
        imagePlacement: StudyCardDraft.ImagePlacement = .none,
        imagePrompt: String? = nil,
        expression: String,
        now: Date = .now
    ) -> StudyManualCardDraft {
        StudyManualCardDraft(
            id: id,
            status: "ready",
            committedCardId: committedCardId,
            creationKind: creationKind,
            cardType: cardType,
            prompt: .object([:]),
            answer: .object(["expression": .string(expression)]),
            imagePlacement: imagePlacement,
            imagePrompt: imagePrompt,
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now
        )
    }
}

private struct DraftCommitStub: Sendable {
    let statusCode: Int
    let data: Data
    let contentType: String?

    static func success(_ data: Data) -> Self {
        .init(statusCode: 200, data: data, contentType: "application/json")
    }

    static func error(_ statusCode: Int, _ message: String) -> Self {
        .init(
            statusCode: statusCode,
            data: Data(#"{"message":"\#(message)"}"#.utf8),
            contentType: "application/json"
        )
    }

    static let noContent = Self(statusCode: 204, data: Data(), contentType: nil)
}

private final class DraftCommitRoute: @unchecked Sendable {
    typealias Matcher = @Sendable (URLRequest) -> Bool
    typealias Inspector = @Sendable (URLRequest) throws -> Void

    private let lock = NSLock()
    private let matcher: Matcher
    private let inspector: Inspector
    private let responses: [DraftCommitStub]
    private var responseIndex = 0

    private init(
        matcher: @escaping Matcher,
        responses: [DraftCommitStub],
        inspector: @escaping Inspector
    ) {
        self.matcher = matcher
        self.responses = responses
        self.inspector = inspector
    }

    func matches(_ request: URLRequest) -> Bool {
        matcher(request)
    }

    func response(for request: URLRequest) throws -> DraftCommitStub {
        try inspector(request)
        return try lock.withLock {
            guard !responses.isEmpty else { throw URLError(.badServerResponse) }
            let response = responses[min(responseIndex, responses.count - 1)]
            responseIndex += 1
            return response
        }
    }

    static func path(
        _ path: String,
        response: DraftCommitStub,
        inspect: @escaping Inspector = { _ in }
    ) -> DraftCommitRoute {
        .init(
            matcher: { $0.url?.path == path },
            responses: [response],
            inspector: inspect
        )
    }

    static func pathContaining(
        _ fragment: String,
        response: DraftCommitStub,
        inspect: @escaping Inspector = { _ in }
    ) -> DraftCommitRoute {
        .init(
            matcher: { $0.url?.path.contains(fragment) == true },
            responses: [response],
            inspector: inspect
        )
    }

    static func pathSuffix(
        _ suffix: String,
        response: DraftCommitStub,
        inspect: @escaping Inspector = { _ in }
    ) -> DraftCommitRoute {
        .init(
            matcher: { $0.url?.path.hasSuffix(suffix) == true },
            responses: [response],
            inspector: inspect
        )
    }

    static func pathSuffix(
        _ suffix: String,
        responses: [DraftCommitStub],
        inspect: @escaping Inspector = { _ in }
    ) -> DraftCommitRoute {
        .init(
            matcher: { $0.url?.path.hasSuffix(suffix) == true },
            responses: responses,
            inspector: inspect
        )
    }

    static func method(
        _ method: String,
        response: DraftCommitStub,
        inspect: @escaping Inspector = { _ in }
    ) -> DraftCommitRoute {
        .init(
            matcher: { $0.httpMethod == method },
            responses: [response],
            inspector: inspect
        )
    }

    static func method(
        _ method: String,
        responses: [DraftCommitStub],
        inspect: @escaping Inspector = { _ in }
    ) -> DraftCommitRoute {
        .init(
            matcher: { $0.httpMethod == method },
            responses: responses,
            inspector: inspect
        )
    }

    static func any(response: DraftCommitStub) -> DraftCommitRoute {
        .init(matcher: { _ in true }, responses: [response], inspector: { _ in })
    }
}

private final class DraftCommitResponseScript: @unchecked Sendable {
    private let paths = LockedRequestPaths()
    private let routes: [DraftCommitRoute]

    init(routes: [DraftCommitRoute]) {
        self.routes = routes
    }

    var requestedPaths: [String] {
        paths.values
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        paths.append(request.url?.path ?? "")
        guard let route = routes.first(where: { $0.matches(request) }) else {
            throw URLError(.badURL)
        }
        let stub = try route.response(for: request)
        return (
            HTTPURLResponse(
                url: request.url!,
                statusCode: stub.statusCode,
                httpVersion: nil,
                headerFields: stub.contentType.map { ["Content-Type": $0] }
            )!,
            stub.data
        )
    }
}
