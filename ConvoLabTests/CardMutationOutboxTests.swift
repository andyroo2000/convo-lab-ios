import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

final class CardMutationOutboxTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    @MainActor
    func testStageOperationsPreserveSequenceWithoutCoalescing() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let outbox = makeOutbox(container: container)
        outbox.activate(userID: 7)
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        let create = try outbox.stageCreate(
            cardID: "card-1",
            request: makeCreateRequest(id: "card-1", cue: "first")
        )
        let firstUpdate = try outbox.stageUpdate(
            cardID: "card-1",
            request: makeUpdateRequest(cue: "second")
        )
        let secondUpdate = try outbox.stageUpdate(
            cardID: "card-1",
            request: makeUpdateRequest(cue: "third")
        )
        let delete = try outbox.stageDelete(cardID: "card-1")
        create.createdAt = base
        firstUpdate.createdAt = base.addingTimeInterval(1)
        secondUpdate.createdAt = base.addingTimeInterval(2)
        delete.createdAt = base.addingTimeInterval(3)
        try container.mainContext.save()

        let pending = try cardMutations(in: container, userID: 7)
        XCTAssertEqual(pending.map(\.kind), [
            "cardCreate", "cardUpdate", "cardUpdate", "cardDelete",
        ])
        XCTAssertEqual(
            try StorageCodec.decoder.decode(
                UpdateStudyCardRequest.self,
                from: pending[1].payload
            ).prompt["cueText"],
            .string("second")
        )
        XCTAssertEqual(
            try StorageCodec.decoder.decode(
                UpdateStudyCardRequest.self,
                from: pending[2].payload
            ).prompt["cueText"],
            .string("third")
        )
    }

    @MainActor
    func testCreateFlushesBeforeDependentUpdateAndRetargetsAliases() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let paths = LockedRequestPaths()
        let clientID = "01CLIENTCARD"
        let serverID = "01servercard"
        let serverCard = makeCard(id: serverID, syncID: serverID, cue: "server")
        let serverCardData = try StorageCodec.encoder.encode(serverCard)
        let client = makeClient { request in
            paths.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            return Self.cardSuccess(serverCardData, for: request)
        }
        let reviewOutbox = ReviewEventOutbox(api: client, context: container.mainContext)
        let outbox = CardMutationOutbox(
            api: client,
            context: container.mainContext,
            reviewOutbox: reviewOutbox
        )
        reviewOutbox.activate(userID: 7)
        outbox.activate(userID: 7)

        let clientCard = makeCard(id: clientID, syncID: clientID, cue: "local")
        container.mainContext.insert(LocalCardRecord(
            card: clientCard,
            userID: 7,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(clientCard)
        ))
        let create = try outbox.stageCreate(
            cardID: clientID,
            request: makeCreateRequest(id: clientID, cue: "local")
        )
        let update = try outbox.stageUpdate(
            cardID: clientID,
            request: makeUpdateRequest(cue: "edited")
        )
        let review = try reviewOutbox.stageEnqueue(
            event: makeReviewEvent(id: "review-1", cardID: clientID),
            cardBefore: clientCard
        )
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        create.createdAt = base
        update.createdAt = base.addingTimeInterval(1)
        review.createdAt = base.addingTimeInterval(2)
        try container.mainContext.save()

        try await outbox.flush { _ in }

        XCTAssertEqual(paths.values, [
            "POST /api/study/cards",
            "PATCH /api/study/cards/\(serverID)",
        ])
        XCTAssertTrue(try cardMutations(in: container, userID: 7).isEmpty)
        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(records.map(\.id), [serverID])
        XCTAssertEqual(records.map(\.normalizedID), [serverID.lowercased()])
        let pendingReview = try XCTUnwrap(
            try allMutations(in: container).first { $0.kind == "review" }
        )
        XCTAssertEqual(pendingReview.resourceID, serverID)
        let reviewPayload = try StorageCodec.decoder.decode(
            PendingReviewPayload.self,
            from: pendingReview.payload
        )
        XCTAssertEqual(reviewPayload.event.cardID, serverID)
        XCTAssertEqual(reviewPayload.event.id, "review-1")
        XCTAssertEqual(reviewPayload.event.clientEventID, "client-review-1")
    }

    @MainActor
    func testTransientFailurePreservesMutationForSuccessfulRetry() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let attempts = LockedCounter()
        let card = makeCard(id: "card-1")
        let cardData = try StorageCodec.encoder.encode(card)
        let client = makeClient { request in
            if attempts.next() == 1 {
                throw URLError(.notConnectedToInternet)
            }
            return Self.cardSuccess(cardData, for: request)
        }
        let outbox = makeOutbox(container: container, client: client)
        outbox.activate(userID: 7)
        _ = try outbox.stageUpdate(
            cardID: card.id,
            request: makeUpdateRequest(cue: "edited")
        )
        try container.mainContext.save()

        do {
            try await outbox.flush { _ in }
            XCTFail("Expected transient failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        let pending = try XCTUnwrap(cardMutations(in: container, userID: 7).first)
        XCTAssertEqual(pending.attemptCount, 1)
        XCTAssertNotNil(pending.lastAttemptAt)
        XCTAssertNil(pending.lastError)

        try await outbox.flush { _ in }

        XCTAssertEqual(attempts.current, 2)
        XCTAssertTrue(try cardMutations(in: container, userID: 7).isEmpty)
    }

    @MainActor
    func testConfirmedRegeneratedAudioStopsWrappingLaterUpdates() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let audio: JSONValue = .object([
            "url": .string("/api/study/media/new-answer"),
        ])
        let answer: JSONValue = .object([
            "meaning": .string("meaning"),
            "answerAudio": audio,
            "answerAudioVoiceId": .string("fishaudio:new-voice"),
            "answerAudioTextOverride": .string("あたらしい"),
        ])
        let baseCard = makeCard(id: "card-1")
        let serverCard = StudyCard(
            id: baseCard.id,
            syncId: baseCard.syncId,
            noteId: baseCard.noteId,
            cardType: baseCard.cardType,
            prompt: baseCard.prompt,
            answer: answer,
            state: baseCard.state,
            answerAudioSource: "generated",
            createdAt: baseCard.createdAt,
            updatedAt: baseCard.updatedAt
        )
        let serverCardData = try StorageCodec.encoder.encode(serverCard)
        let client = makeClient { request in
            Self.cardSuccess(serverCardData, for: request)
        }
        let outbox = makeOutbox(container: container, client: client)
        outbox.activate(userID: 7)
        try outbox.trackRegeneratedAnswerAudio(cardID: serverCard.id, answer: answer)
        let request = UpdateStudyCardRequest(prompt: serverCard.prompt, answer: answer)
        _ = try outbox.stageUpdate(cardID: serverCard.id, request: request)
        try container.mainContext.save()

        try await outbox.flush { _ in }
        XCTAssertTrue(try allMutations(in: container).isEmpty)

        let ordinaryUpdate = try outbox.stageUpdate(
            cardID: serverCard.id,
            request: request
        )
        XCTAssertNoThrow(try StorageCodec.decoder.decode(
            UpdateStudyCardRequest.self,
            from: ordinaryUpdate.payload
        ))
    }

    @MainActor
    func testPromptAudioMismatchStillProtectsRegeneratedAnswerAudio() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let baseCard = makeCard(id: "card-1")
        let answerAudio: JSONValue = .object([
            "url": .string("/api/study/media/new-answer"),
        ])
        let answer = baseCard.answer.replacingObjectValues([
            "answerAudio": answerAudio,
        ])
        let regeneratedPrompt = baseCard.prompt.replacingObjectValues([
            "cueAudio": .object([
                "url": .string("/api/study/media/regenerated-prompt"),
            ]),
        ])
        let editedPrompt = baseCard.prompt.replacingObjectValues([
            "cueAudio": .object([
                "url": .string("/api/study/media/edited-prompt"),
            ]),
        ])
        let serverData = try StorageCodec.encoder.encode(baseCard)
        let client = makeClient { request in
            Self.cardSuccess(serverData, for: request)
        }
        let outbox = makeOutbox(container: container, client: client)
        outbox.activate(userID: 7)
        try outbox.trackRegeneratedAnswerAudio(
            cardID: baseCard.id,
            prompt: regeneratedPrompt,
            answer: answer
        )
        _ = try outbox.stageUpdate(
            cardID: baseCard.id,
            request: UpdateStudyCardRequest(prompt: editedPrompt, answer: answer)
        )
        try container.mainContext.save()
        var acknowledgement: CardMutationAcknowledgement?

        try await outbox.flush { acknowledgement = $0 }

        XCTAssertNil(acknowledgement?.submittedPromptAudio)
        XCTAssertEqual(
            acknowledgement?.submittedAnswerAudioFields?["answerAudio"],
            answerAudio
        )
    }

    @MainActor
    func testAudioProtectedUpdateKeepsFailedChangeDetail() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let outbox = makeOutbox(container: container)
        outbox.activate(userID: 7)
        let answer: JSONValue = .object([
            "meaning": .string("meaning"),
            "answerAudio": .object([
                "url": .string("/api/study/media/new-answer"),
            ]),
        ])
        try outbox.trackRegeneratedAnswerAudio(cardID: "card-1", answer: answer)
        let update = try outbox.stageUpdate(
            cardID: "card-1",
            request: UpdateStudyCardRequest(
                prompt: .object(["cueText": .string("edited cue")]),
                answer: answer
            )
        )
        update.lastError = "HTTP 422: Invalid card"
        try container.mainContext.save()

        XCTAssertEqual(update.failedStudyChange()?.detail, "edited cue")
        for mutation in try allMutations(in: container) {
            container.mainContext.delete(mutation)
        }
        try container.mainContext.save()
    }

    @MainActor
    func testDeletingCardClearsAnswerAudioReconciliationMarker() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let outbox = makeOutbox(container: container)
        outbox.activate(userID: 7)
        try outbox.trackRegeneratedAnswerAudio(
            cardID: "card-1",
            answer: .object([
                "answerAudio": .object([
                    "url": .string("/api/study/media/new-answer"),
                ]),
            ])
        )

        _ = try outbox.stageDelete(cardID: "card-1")
        try container.mainContext.save()

        let remaining = try allMutations(in: container)
        XCTAssertEqual(remaining.map(\.kind), ["cardDelete"])
        remaining.forEach(container.mainContext.delete)
        try container.mainContext.save()
    }

    @MainActor
    func testPermanentRejectionQuarantinesMutationAndContinuesInOrder() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let attempts = LockedCounter()
        let card = makeCard(id: "card-1")
        let cardData = try StorageCodec.encoder.encode(card)
        let client = makeClient { request in
            if attempts.next() == 1 {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 422,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"message":"Invalid card"}"#.utf8)
                )
            }
            return Self.cardSuccess(cardData, for: request)
        }
        let outbox = makeOutbox(container: container, client: client)
        outbox.activate(userID: 7)
        let rejected = try outbox.stageUpdate(
            cardID: card.id,
            request: makeUpdateRequest(cue: "invalid")
        )
        let accepted = try outbox.stageUpdate(
            cardID: card.id,
            request: makeUpdateRequest(cue: "valid")
        )
        rejected.createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        accepted.createdAt = Date(timeIntervalSince1970: 1_800_000_001)
        try container.mainContext.save()

        do {
            try await outbox.flush { _ in }
            XCTFail("Expected quarantined card error")
        } catch let error as QuarantinedCardMutationError {
            XCTAssertEqual(error.count, 1)
        }

        let pending = try cardMutations(in: container, userID: 7)
        XCTAssertEqual(pending.map(\.id), [rejected.id])
        XCTAssertEqual(pending.first?.attemptCount, 1)
        XCTAssertEqual(pending.first?.lastError, "HTTP 422: Invalid card")
        XCTAssertEqual(attempts.current, 2)
    }

    @MainActor
    func testMissingDeleteIsAcknowledgedAndRemoved() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let requests = LockedRequestPaths()
        let client = makeClient { request in
            requests.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"message":"Not Found"}"#.utf8)
            )
        }
        let outbox = makeOutbox(container: container, client: client)
        outbox.activate(userID: 7)
        _ = try outbox.stageDelete(cardID: "card-1")
        try container.mainContext.save()

        try await outbox.flush { _ in }

        XCTAssertEqual(requests.values, ["DELETE /api/study/cards/card-1"])
        XCTAssertTrue(try cardMutations(in: container, userID: 7).isEmpty)
    }

    @MainActor
    func testPendingMutationLookupIsCaseInsensitiveAndAccountScoped() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let outbox = makeOutbox(container: container)
        outbox.activate(userID: 7)
        _ = try outbox.stageUpdate(
            cardID: "01CARD",
            request: makeUpdateRequest(cue: "edited")
        )
        try container.mainContext.save()

        XCTAssertTrue(try outbox.hasPendingMutation(for: "01card", userID: 7))
        XCTAssertFalse(try outbox.hasPendingMutation(for: "01card", userID: 8))
    }

    @MainActor
    func testAccountSwitchKeepsNewUsersFlushIndependentAndOldMutationUntouched() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let (oldStarted, oldStartedContinuation) = AsyncStream<Void>.makeStream()
        let (newStarted, newStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releaseOld, releaseOldContinuation) = AsyncStream<Void>.makeStream()
        let (releaseNew, releaseNewContinuation) = AsyncStream<Void>.makeStream()
        let requestOrder = LockedCounter()
        let newRequestCount = LockedCounter()
        let oldCardData = try StorageCodec.encoder.encode(makeCard(id: "card-1", cue: "old"))
        let newCardData = try StorageCodec.encoder.encode(makeCard(id: "card-1", cue: "new"))
        let client = makeDeferredClient { request, completion in
            let isOldRequest = requestOrder.next() == 1
            let release: AsyncStream<Void>
            if isOldRequest {
                oldStartedContinuation.yield()
                release = releaseOld
            } else {
                _ = newRequestCount.next()
                newStartedContinuation.yield()
                release = releaseNew
            }
            Task {
                for await _ in release {
                    completion(.success(Self.cardSuccess(
                        isOldRequest ? oldCardData : newCardData,
                        for: request
                    )))
                    return
                }
            }
        }
        let outbox = makeOutbox(container: container, client: client)
        outbox.activate(userID: 1)
        _ = try outbox.stageUpdate(
            cardID: "card-1",
            request: makeUpdateRequest(cue: "old")
        )
        try container.mainContext.save()
        let oldFlush = Task { try await outbox.flush { _ in } }
        for await _ in oldStarted { break }

        outbox.activate(userID: 2)
        _ = try outbox.stageUpdate(
            cardID: "card-1",
            request: makeUpdateRequest(cue: "new")
        )
        try container.mainContext.save()
        let newFlush = Task { try await outbox.flush { _ in } }
        for await _ in newStarted { break }

        releaseOldContinuation.yield()
        _ = try? await oldFlush.value
        let joinedNewFlush = Task { try await outbox.flush { _ in } }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(newRequestCount.current, 1)

        releaseNewContinuation.yield()
        try await newFlush.value
        try await joinedNewFlush.value

        XCTAssertTrue(try cardMutations(in: container, userID: 2).isEmpty)
        XCTAssertEqual(try cardMutations(in: container, userID: 1).count, 1)
    }

    @MainActor
    private func makeOutbox(
        container: ModelContainer,
        client: APIClient? = nil
    ) -> CardMutationOutbox {
        let resolvedClient = client ?? makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        let reviewOutbox = ReviewEventOutbox(
            api: resolvedClient,
            context: container.mainContext
        )
        return CardMutationOutbox(
            api: resolvedClient,
            context: container.mainContext,
            reviewOutbox: reviewOutbox
        )
    }

    @MainActor
    private func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
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
    private func makeDeferredClient(
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
    private func cardMutations(
        in container: ModelContainer,
        userID: Int
    ) throws -> [PendingMutation] {
        try container.mainContext.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID
                        && ($0.kind == "cardCreate"
                            || $0.kind == "cardUpdate"
                            || $0.kind == "cardDelete")
                },
                sortBy: [SortDescriptor(\.createdAt)]
            )
        )
    }

    @MainActor
    private func allMutations(in container: ModelContainer) throws -> [PendingMutation] {
        try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
    }

    private func makeCreateRequest(id: String, cue: String) -> CreateStudyCardRequest {
        CreateStudyCardRequest(
            id: id,
            cardType: "recognition",
            prompt: .object(["cueText": .string(cue)]),
            answer: .object(["meaning": .string("meaning")])
        )
    }

    private func makeUpdateRequest(cue: String) -> UpdateStudyCardRequest {
        UpdateStudyCardRequest(
            prompt: .object(["cueText": .string(cue)]),
            answer: .object(["meaning": .string("meaning")])
        )
    }

    private func makeReviewEvent(
        id: String,
        cardID: String
    ) -> ReviewBatchRequest.Event {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return ReviewBatchRequest.Event(
            id: id,
            cardID: cardID,
            rating: .good,
            reviewedAt: date,
            durationMilliseconds: 500,
            clientEventID: "client-\(id)",
            deviceID: "device-1",
            clientCreatedAt: date
        )
    }

    @MainActor
    private func makeCard(
        id: String,
        syncID: String? = nil,
        cue: String = "cue"
    ) -> StudyCard {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return StudyCard(
            id: id,
            syncId: syncID,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string(cue)]),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: date,
                introducedAt: date,
                failedAt: nil,
                queueState: "review",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: date,
            updatedAt: date
        )
    }

    private static func cardSuccess(
        _ data: Data,
        for request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            data
        )
    }
}
