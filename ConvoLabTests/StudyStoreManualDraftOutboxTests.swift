import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

private struct ManualDraftFixtureSpec {
    let id: String
    var status = "ready"
    let content: ManualDraftFixtureContent
}

private enum ManualDraftFixtureContent {
    case textRecognition(expression: String)
    case audioRecognition(expression: String)
    case productionImage(expression: String, meaning: String, prompt: String)
}

extension StudyStoreTests {
    @MainActor
    func testManualDraftRefreshConsumesEveryCursorPage() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let firstID = "01J0000000000000000000000P1"
        let secondID = "01J0000000000000000000000P2"
        let firstDraft = makeOutboxDraft(.init(
            id: firstID,
            content: .audioRecognition(expression: firstID)
        ))
        let secondDraft = makeOutboxDraft(.init(
            id: secondID,
            content: .audioRecognition(expression: secondID)
        ))
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
        let store = makeManualDraftStore(container: container, client: client)

        try await store.refreshManualDrafts()

        XCTAssertEqual(store.manualDrafts.map(\.id), [firstDraft.id, secondDraft.id])
        XCTAssertEqual(requestedURLs.values.count, 2)
        XCTAssertTrue(requestedURLs.values[0].contains("limit=200"))
        XCTAssertTrue(requestedURLs.values[1].contains("cursor=next-page"))
    }

    @MainActor
    func testImageProductionDraftQueuesAndPlainDraftDeleteRemovesIt() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let serverDraft = makeOutboxDraft(.init(
            id: "01J0000000000000000000000Q1",
            status: "generating",
            content: .productionImage(
                expression: "会社",
                meaning: "company",
                prompt: "A Japanese company office"
            )
        ))
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
        let store = makeManualDraftStore(container: container, client: client)
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
        let serverDraft = makeOutboxDraft(.init(
            id: clientDraftID.lowercased(),
            status: "generating",
            content: .audioRecognition(expression: "犬")
        ))
        let responseData = try StorageCodec.encoder.encode(serverDraft)
        let server = LostDraftCreateServer(successData: responseData)
        let client = makeClient { try server.response(for: $0) }
        let store = makeManualDraftStore(container: container, client: client)
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
        XCTAssertEqual(
            store.pendingManualDraftCreates.map(\.id),
            [clientDraftID]
        )

        let relaunchedStore = makeManualDraftStore(container: container, client: client)
        let pendingChanged = expectation(
            description: "Synchronization publishes pending create removal"
        )
        withObservationTracking {
            _ = relaunchedStore.pendingManualDraftCreates
        } onChange: {
            pendingChanged.fulfill()
        }

        await relaunchedStore.synchronize()
        await fulfillment(of: [pendingChanged], timeout: 1)

        async let firstDuplicateRetry: Void = relaunchedStore.retryPendingDraftCreates()
        async let secondDuplicateRetry: Void = relaunchedStore.retryPendingDraftCreates()
        _ = try await (firstDuplicateRetry, secondDuplicateRetry)

        XCTAssertEqual(server.requestIDs, [clientDraftID, clientDraftID])
        XCTAssertEqual(
            server.draftRequestPaths,
            ["POST /api/study/card-drafts", "POST /api/study/card-drafts"]
        )
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
        let store = makeManualDraftStore(container: container, client: client)
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
        XCTAssertTrue(store.pendingManualDraftCreates.isEmpty)

        try await store.retryPendingDraftCreates()

        XCTAssertEqual(attempts.current, 1)
        XCTAssertEqual(store.quarantinedMutationCount, 1)
    }

    @MainActor
    func testManualDraftCreateRetryUsesLatestEditedPayload() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let clientDraftID = ClientIdentifier.ulid()
        let serverDraft = makeOutboxDraft(.init(
            id: clientDraftID.lowercased(),
            status: "generating",
            content: .audioRecognition(expression: "猫")
        ))
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
        let store = makeManualDraftStore(container: container, client: client)
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
        let store = makeManualDraftStore(container: container, client: client)
        var draft = StudyCardDraft(cardType: .recognition)
        draft.isAudioLedPrompt = true
        draft.isMediaLedPrompt = true
        draft.answerExpression = "犬"

        _ = try await store.updateManualDraft(serverDraft, draft: draft)
    }

    @MainActor
    func testStudyStorePublishesManualDraftOutboxRefresh() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let serverDraft = makeOutboxDraft(.init(
            id: "01J00000000000000000000O1",
            content: .textRecognition(expression: "観察")
        ))
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
        let store = makeManualDraftStore(container: container, client: client)
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
        let oldDraft = makeOutboxDraft(.init(
            id: "01J00000000000000000000O2",
            content: .textRecognition(expression: "前の利用者")
        ))
        let newDraft = makeOutboxDraft(.init(
            id: "01J00000000000000000000O3",
            content: .textRecognition(expression: "現在の利用者")
        ))
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
        let store = makeManualDraftStore(container: container, client: client)
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
        try insertDraftCommit(
            draftID: draftID,
            cardID: clientCardID,
            into: container
        )
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
        let store = makeManualDraftStore(container: container, client: client)

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
        let store = makeManualDraftStore(container: container, client: client)

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
        let serverDraft = makeOutboxDraft(.init(
            id: draftID,
            status: "ready",
            content: .audioRecognition(expression: "一回")
        ))
        let committedCard = makeCard(
            id: clientCardID.lowercased(),
            expression: "一回"
        )
        let committedData = try StorageCodec.encoder.encode(committedCard)
        try insertDraftCommit(
            draftID: draftID,
            cardID: clientCardID,
            into: container
        )
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
        let store = makeManualDraftStore(container: container, client: client)
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
    private func makeManualDraftStore(
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
    private func makeOutboxDraft(_ spec: ManualDraftFixtureSpec) -> StudyManualCardDraft {
        let fields: (
            kind: StudyCardCreationKind,
            cardType: String,
            prompt: JSONValue,
            answer: JSONValue,
            imagePlacement: StudyCardDraft.ImagePlacement,
            imagePrompt: String?
        )
        switch spec.content {
        case let .textRecognition(expression):
            fields = (
                .textRecognition,
                "recognition",
                .object(["cueText": .string(expression)]),
                .object(["meaning": .string("meaning")]),
                .none,
                nil
            )
        case let .audioRecognition(expression):
            fields = (
                .audioRecognition,
                "recognition",
                .object([:]),
                .object(["expression": .string(expression)]),
                .none,
                nil
            )
        case let .productionImage(expression, meaning, prompt):
            fields = (
                .productionImage,
                "production",
                .object([:]),
                .object([
                    "expression": .string(expression),
                    "meaning": .string(meaning),
                ]),
                .prompt,
                prompt
            )
        }
        return StudyManualCardDraft(
            id: spec.id,
            status: spec.status,
            committedCardId: nil,
            creationKind: fields.kind,
            cardType: fields.cardType,
            prompt: fields.prompt,
            answer: fields.answer,
            imagePlacement: fields.imagePlacement,
            imagePrompt: fields.imagePrompt,
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil,
            errorMessage: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }

    @MainActor
    private func insertDraftCommit(
        draftID: String,
        cardID: String,
        into container: ModelContainer
    ) throws {
        container.mainContext.insert(PendingMutation(
            kind: "draftCommit",
            userID: 1,
            resourceID: draftID,
            payload: try StorageCodec.encoder.encode(
                CreateCardFromStudyManualDraftRequest(id: cardID)
            )
        ))
        try container.mainContext.save()
    }
}

private final class LostDraftCreateServer: @unchecked Sendable {
    private let attempts = LockedCounter()
    private let requestIDValues = LockedRequestPaths()
    private let draftPathValues = LockedRequestPaths()
    private let successData: Data

    init(successData: Data) {
        self.successData = successData
    }

    var requestIDs: [String] { requestIDValues.values }
    var draftRequestPaths: [String] { draftPathValues.values }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let path = request.url?.path ?? ""
        guard path == "/api/study/card-drafts", request.httpMethod == "POST" else {
            if path.hasPrefix("/api/study/card-drafts") {
                draftPathValues.append("\(request.httpMethod ?? "") \(path)")
            }
            return Self.response(
                request: request,
                statusCode: 503,
                data: Data(#"{"message":"offline"}"#.utf8)
            )
        }
        draftPathValues.append("POST /api/study/card-drafts")
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try requestBody(request)) as? [String: Any]
        )
        requestIDValues.append(try XCTUnwrap(payload["id"] as? String))
        if attempts.next() == 1 {
            return Self.response(
                request: request,
                statusCode: 500,
                data: Data(#"{"message":"response lost"}"#.utf8)
            )
        }
        return Self.response(request: request, statusCode: 200, data: successData)
    }

    private static func response(
        request: URLRequest,
        statusCode: Int,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            data
        )
    }
}
