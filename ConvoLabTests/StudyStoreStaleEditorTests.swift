import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
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
        try insertEditorCard(canonicalCard, into: container)
        let patchedPaths = LockedRequestPaths()
        let client = makeCanonicalPatchClient(card: canonicalCard, paths: patchedPaths)
        let store = makeEditorStore(container: container, client: client)
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
        let store = makeEditorStore(container: container, client: client)
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
    func testSyncAcknowledgementDoesNotRecreateMissingLocalCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let serverCard = makeCard(id: "missing-local-card", expression: "server response")
        container.mainContext.insert(
            PendingMutation(
                kind: "cardUpdate",
                userID: 1,
                resourceID: serverCard.id,
                payload: try StorageCodec.encoder.encode(
                    UpdateStudyCardRequest(
                        prompt: serverCard.prompt,
                        answer: serverCard.answer
                    )
                )
            )
        )
        try container.mainContext.save()
        let responseData = try StorageCodec.encoder.encode(serverCard)
        let client = makeClient { request in
            if request.httpMethod == "PATCH" {
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
            throw URLError(.notConnectedToInternet)
        }
        let store = makeEditorStore(container: container, client: client)

        await store.synchronize()

        XCTAssertEqual(
            store.syncStatus,
            .failed(
                "Card sync stopped because its local record is missing. Refresh and try again."
            )
        )
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
        let mutation = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>()).first
        )
        XCTAssertEqual(mutation.kind, "cardUpdate")
        XCTAssertEqual(mutation.attemptCount, 1)
        XCTAssertNil(mutation.lastError)
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
        try insertEditorCard(canonicalCard, into: container)
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
        let store = makeEditorStore(container: container, client: client)

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
    private func makeCanonicalPatchClient(
        card: StudyCard,
        paths: LockedRequestPaths
    ) -> APIClient {
        let canonicalID = card.id
        let cardType = card.cardType
        let audioSource = card.answerAudioSource
        return makeClient { request in
            paths.append(request.url?.path ?? "")
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            )
            let response: [String: Any] = [
                "id": canonicalID,
                "syncId": canonicalID,
                "noteId": NSNull(),
                "cardType": cardType,
                "prompt": try XCTUnwrap(body["prompt"]),
                "answer": try XCTUnwrap(body["answer"]),
                "state": [
                    "dueAt": NSNull(), "introducedAt": NSNull(), "failedAt": NSNull(),
                    "queueState": "new", "scheduler": NSNull(), "source": [:],
                ],
                "answerAudioSource": audioSource as Any,
                "createdAt": "2026-07-24T11:00:00Z",
                "updatedAt": "2026-07-24T11:01:00Z",
            ]
            return Self.response(data: try JSONSerialization.data(withJSONObject: response))
        }
    }
}
