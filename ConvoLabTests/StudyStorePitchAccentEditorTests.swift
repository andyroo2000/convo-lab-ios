import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testPitchAccentResolutionPersistsServerEnrichmentWithoutChangingSchedule() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let (card, serverCard) = makePitchAccentEnrichmentCards()
        try insertEditorCard(card, into: container)
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
        let store = makeEditorStore(container: container, client: client)

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
        try insertEditorCard(card, into: container)
        let requestCount = LockedCounter()
        let client = makeClient { _ in
            _ = requestCount.next()
            throw URLError(.badServerResponse)
        }
        let store = makeEditorStore(container: container, client: client)

        await store.resolvePitchAccent(for: card)
        await store.resolvePitchAccent(for: card)

        XCTAssertEqual(requestCount.current, 0)
        XCTAssertNil(store.cards.first?.presentation.back.pitchAccent)
    }

    @MainActor
    func testPitchAccentResolutionFollowsCreateAcknowledgementToCanonicalID() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let clientID = "01J000000000000000000000PX"
        let serverID = clientID.lowercased()
        let clientCard = makeCard(id: clientID, expression: "会社")
        let serverCard = clientCard.replacingIdentity(id: serverID, syncId: serverID)
        try insertEditorCard(clientCard, into: container)
        container.mainContext.insert(
            PendingMutation(
                kind: "cardCreate",
                userID: 1,
                resourceID: clientID,
                payload: try StorageCodec.encoder.encode(
                    CreateStudyCardRequest(
                        id: clientID,
                        cardType: clientCard.cardType,
                        prompt: clientCard.prompt,
                        answer: clientCard.answer
                    )
                )
            )
        )
        try container.mainContext.save()
        let createResponse = try StorageCodec.encoder.encode(serverCard)
        let pitchResponse = try StorageCodec.encoder.encode(
            cardWithResolvedPitchAccent(serverCard)
        )
        let paths = LockedRequestPaths()
        let gate = LockedRequestGate()
        let client = makeCreateThenPitchClient(
            createResponse: createResponse,
            pitchResponse: pitchResponse,
            paths: paths,
            gate: gate
        )
        let store = makeEditorStore(container: container, client: client)

        let resolution = Task { await store.resolvePitchAccent(for: clientCard) }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)
        XCTAssertEqual(store.cards.first?.id, serverID)
        XCTAssertTrue(store.resolvingPitchAccentCardIDs.contains(serverID))
        gate.release()
        await resolution.value

        XCTAssertEqual(paths.values, [
            "/api/study/cards",
            "/api/study/cards/\(serverID)/pitch-accent",
        ])
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        XCTAssertEqual(record.id, serverID)
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(persisted.presentation.back.pitchAccent?.reading, "かいしゃ")
        XCTAssertEqual(store.cards.first?.id, serverID)
        XCTAssertEqual(store.cards.first?.presentation.back.pitchAccent?.reading, "かいしゃ")
    }

    @MainActor
    func testPitchAccentResponseIsDiscardedAfterAccountSwitch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let sharedID = "shared-pitch-card"
        let firstUserCard = makeCard(id: sharedID, expression: "会社")
        let secondUserCard = makeCard(id: sharedID, expression: "別のカード")
        for (userID, card) in [(1, firstUserCard), (2, secondUserCard)] {
            container.mainContext.insert(
                LocalCardRecord(
                    card: card,
                    userID: userID,
                    queueIndex: 0,
                    payload: try StorageCodec.encoder.encode(card)
                )
            )
        }
        try container.mainContext.save()
        let responseData = try StorageCodec.encoder.encode(
            cardWithResolvedPitchAccent(firstUserCard)
        )
        let gate = LockedRequestGate()
        let client = makeDelayedPitchClient(responseData: responseData, gate: gate)
        let store = makeEditorStore(container: container, client: client)

        let resolution = Task { await store.resolvePitchAccent(for: firstUserCard) }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)
        store.activate(userID: 2)
        gate.release()
        await resolution.value

        XCTAssertEqual(store.cards.first?.promptText, "別のカード")
        XCTAssertNil(store.cards.first?.presentation.back.pitchAccent)
        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        for record in records {
            let persisted = try StorageCodec.decoder.decode(
                StudyCard.self,
                from: record.payload
            )
            XCTAssertNil(persisted.presentation.back.pitchAccent)
        }
    }

    @MainActor
    func testPitchAccentResolutionPreservesReviewThatFinishesDuringRequest() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J000000000000000000000PR",
            expression: "会社"
        )
        try insertEditorCard(card, into: container)
        let serverCard = cardWithResolvedPitchAccent(card)
        let responseData = try StorageCodec.encoder.encode(serverCard)
        let gate = LockedRequestGate()
        let client = makeDelayedPitchClient(responseData: responseData, gate: gate)
        let store = makeEditorStore(container: container, client: client)

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
    func testPitchAccentResolutionRejectsResultAfterCardTextChanges() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let baseCard = makeCard(
            id: "01J000000000000000000000PT",
            expression: "会社"
        )
        let card = StudyCard(
            id: baseCard.id,
            syncId: baseCard.syncId,
            noteId: baseCard.noteId,
            cardType: baseCard.cardType,
            prompt: baseCard.prompt,
            answer: baseCard.answer.replacingObjectValues([
                "expression": .string("会社"),
                "expressionReading": .string("かいしゃ"),
            ]),
            state: baseCard.state,
            answerAudioSource: baseCard.answerAudioSource,
            masteryLevel: baseCard.masteryLevel,
            createdAt: baseCard.createdAt,
            updatedAt: baseCard.updatedAt
        )
        try insertEditorCard(card, into: container)
        let responseData = try StorageCodec.encoder.encode(cardWithResolvedPitchAccent(card))
        let gate = LockedRequestGate()
        let client = makeDelayedPitchClient(responseData: responseData, gate: gate)
        let store = makeEditorStore(container: container, client: client)

        let resolution = Task { await store.resolvePitchAccent(for: card) }
        await waitUntil { gate.hasStarted }
        XCTAssertTrue(gate.hasStarted)
        let editedCard = StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer.replacingObjectValues([
                "expression": .string("学校"),
                "expressionReading": .string("がっこう"),
            ]),
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            masteryLevel: card.masteryLevel,
            createdAt: card.createdAt,
            updatedAt: card.updatedAt.addingTimeInterval(1)
        )
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        record.replacePayload(encoded: try StorageCodec.encoder.encode(editedCard))
        try container.mainContext.save()
        gate.release()
        await resolution.value

        let persisted = try persistedCard(in: container)
        XCTAssertEqual(persisted.answer["expression"]?.stringValue, "学校")
        XCTAssertNil(persisted.presentation.back.pitchAccent)
    }

    @MainActor
    func testPitchAccentResolutionDoesNotResurrectCardDeletedDuringRequest() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J000000000000000000000PD",
            expression: "会社"
        )
        try insertEditorCard(card, into: container)
        let responseData = try StorageCodec.encoder.encode(cardWithResolvedPitchAccent(card))
        let gate = LockedRequestGate()
        let client = makeDelayedPitchClient(responseData: responseData, gate: gate)
        let store = makeEditorStore(container: container, client: client)

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
    private func makePitchAccentEnrichmentCards() -> (StudyCard, StudyCard) {
        let original = makeCard(id: "compatibility-card-id", expression: "会社")
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
        return (card, serverCard)
    }

    @MainActor
    private func makeCreateThenPitchClient(
        createResponse: Data,
        pitchResponse: Data,
        paths: LockedRequestPaths,
        gate: LockedRequestGate
    ) -> APIClient {
        makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.hasSuffix("/pitch-accent") {
                gate.markStarted()
                gate.waitForRelease()
                return Self.response(data: pitchResponse)
            }
            return Self.response(data: createResponse)
        }
    }
}
