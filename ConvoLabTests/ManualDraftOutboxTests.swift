import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

final class ManualDraftOutboxTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    @MainActor
    func testRetryRunsDraftCreateBeforeDependentCommit() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000D1"
        let cardID = "01J0000000000000000000000C1"
        let draft = makeDraft(id: draftID)
        let card = makeCard(id: cardID)
        let draftData = try StorageCodec.encoder.encode(draft)
        let cardData = try StorageCodec.encoder.encode(card)
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            paths.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/study/card-drafts"):
                return Self.response(status: 200, data: draftData, request: request)
            case ("POST", "/api/study/card-drafts/\(draftID)/create-card"):
                return Self.response(status: 200, data: cardData, request: request)
            case ("DELETE", "/api/study/card-drafts/\(draftID)"):
                return Self.response(status: 204, request: request)
            default:
                throw URLError(.badServerResponse)
            }
        }
        let outbox = ManualDraftOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        _ = try outbox.stageCreate(makeCreateRequest(id: draftID))
        _ = try outbox.stageCommit(draftID: draftID, cardID: cardID)

        try await outbox.retryPendingMutations { _ in }

        XCTAssertEqual(paths.values, [
            "POST /api/study/card-drafts",
            "POST /api/study/card-drafts/\(draftID)/create-card",
            "DELETE /api/study/card-drafts/\(draftID)",
        ])
        XCTAssertTrue(try mutations(in: container, userID: 7).isEmpty)
        XCTAssertTrue(outbox.drafts.isEmpty)
    }

    @MainActor
    func testTransientCreateFailureRemainsEligibleForRetry() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000D2"
        let draftData = try StorageCodec.encoder.encode(makeDraft(id: draftID))
        let attempts = LockedCounter()
        let client = makeClient { request in
            if attempts.next() == 1 {
                throw URLError(.notConnectedToInternet)
            }
            return Self.response(status: 200, data: draftData, request: request)
        }
        let outbox = ManualDraftOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        _ = try outbox.stageCreate(makeCreateRequest(id: draftID))

        do {
            try await outbox.retryPendingCreates()
            XCTFail("Expected transient failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        let pending = try XCTUnwrap(mutations(in: container, userID: 7).first)
        XCTAssertEqual(pending.attemptCount, 1)
        XCTAssertNotNil(pending.lastAttemptAt)
        XCTAssertNil(pending.lastError)

        try await outbox.retryPendingCreates()

        XCTAssertEqual(attempts.current, 2)
        XCTAssertTrue(try mutations(in: container, userID: 7).isEmpty)
        XCTAssertEqual(outbox.drafts.map(\.id), [draftID])
    }

    @MainActor
    func testPermanentCreateRejectionIsQuarantinedFromBackgroundRetry() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let attempts = LockedCounter()
        let client = makeClient { request in
            _ = attempts.next()
            return Self.response(
                status: 422,
                data: Data(#"{"message":"invalid draft"}"#.utf8),
                request: request
            )
        }
        let outbox = ManualDraftOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        _ = try outbox.stageCreate(
            makeCreateRequest(id: "01J0000000000000000000000D3")
        )

        do {
            try await outbox.retryPendingCreates()
            XCTFail("Expected permanent rejection")
        } catch let APIClientError.rejected(status, _) {
            XCTAssertEqual(status, 422)
        }
        let pending = try XCTUnwrap(mutations(in: container, userID: 7).first)
        XCTAssertNotNil(pending.lastError)

        try await outbox.retryPendingCreates()
        XCTAssertEqual(attempts.current, 1)
    }

    @MainActor
    func testRecoveryStateReportsOutcomeRejectedAndCleanupPending() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000D4"
        let originalCardID = "01J0000000000000000000000C4"
        let outbox = makeOutbox(container: container)
        outbox.activate(userID: 7)

        XCTAssertEqual(outbox.recoveryState(for: draftID), .none)
        let mutation = try outbox.stageCommit(
            draftID: draftID,
            cardID: originalCardID.uppercased()
        )
        XCTAssertEqual(outbox.recoveryState(for: draftID), .outcomeUnknown)

        let card = makeCard(id: originalCardID.lowercased())
        container.mainContext.insert(LocalCardRecord(
            card: card,
            userID: 7,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        ))
        try container.mainContext.save()
        XCTAssertEqual(outbox.recoveryState(for: draftID), .cleanupPending)

        mutation.kind = "draftCommitRejected"
        try container.mainContext.save()
        XCTAssertEqual(outbox.recoveryState(for: draftID), .rejected)
    }

    @MainActor
    func testConflictUsesCanonicalDraftCardIDToClassifyDuplicate() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000D5"
        let cardID = "01J0000000000000000000000C5"
        let canonical = makeDraft(id: draftID, committedCardID: cardID.lowercased())
        let canonicalData = try StorageCodec.encoder.encode(canonical)
        let client = makeClient { request in
            if request.httpMethod == "POST" {
                return Self.response(
                    status: 409,
                    data: Data(#"{"message":"already committed"}"#.utf8),
                    request: request
                )
            }
            return Self.response(status: 200, data: canonicalData, request: request)
        }
        let outbox = ManualDraftOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        let mutation = try outbox.stageCommit(
            draftID: draftID,
            cardID: cardID.uppercased()
        )

        do {
            try await outbox.retryPendingCommits { _ in }
            XCTFail("Expected conflict")
        } catch let APIClientError.rejected(status, _) {
            XCTAssertEqual(status, 409)
        }

        XCTAssertEqual(mutation.kind, "draftCommit")
        XCTAssertNil(mutation.lastError)
        XCTAssertEqual(outbox.drafts.first?.committedCardId, cardID.lowercased())
        XCTAssertEqual(outbox.recoveryState(for: draftID), .outcomeUnknown)
    }

    @MainActor
    func testConflictWithDifferentCommittedCardIDIsPermanentlyRejected() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000D6"
        let clientCardID = "01J0000000000000000000000C6"
        let otherCardID = "01J0000000000000000000000FF"
        let canonicalData = try StorageCodec.encoder.encode(
            makeDraft(id: draftID, committedCardID: otherCardID)
        )
        let client = makeClient { request in
            if request.httpMethod == "POST" {
                return Self.response(
                    status: 409,
                    data: Data(#"{"message":"already committed"}"#.utf8),
                    request: request
                )
            }
            return Self.response(status: 200, data: canonicalData, request: request)
        }
        let outbox = ManualDraftOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        let mutation = try outbox.stageCommit(draftID: draftID, cardID: clientCardID)

        do {
            try await outbox.retryPendingCommits { _ in }
            XCTFail("Expected conflict")
        } catch let APIClientError.rejected(status, _) {
            XCTAssertEqual(status, 409)
        }

        XCTAssertEqual(mutation.kind, "draftCommitRejected")
        XCTAssertNotNil(mutation.lastError)
        XCTAssertEqual(outbox.recoveryState(for: draftID), .rejected)
    }

    @MainActor
    func testConflictLookupCannotOverwriteNewerDraftWhileRequestIsInFlight() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000DK"
        let clientCardID = "01J0000000000000000000000CK"
        let stale = makeDraft(
            id: draftID,
            committedCardID: "01J0000000000000000000000FK",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let newer = makeDraft(
            id: draftID,
            committedCardID: clientCardID,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let staleData = try StorageCodec.encoder.encode(stale)
        let deferredFetch = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            if request.httpMethod == "POST" {
                completion(.success(Self.response(
                    status: 409,
                    data: Data(#"{"message":"already committed"}"#.utf8),
                    request: request
                )))
            } else {
                deferredFetch.hold(completion)
            }
        }
        let outbox = ManualDraftOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        let mutation = try outbox.stageCommit(draftID: draftID, cardID: clientCardID)

        let retry = Task { try await outbox.retryPendingCommits { _ in } }
        for _ in 0..<100 where !deferredFetch.hasPendingResponse {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(deferredFetch.hasPendingResponse)
        outbox.replace(newer)
        deferredFetch.succeed(with: Self.response(
            status: 200,
            data: staleData,
            request: URLRequest(url: URL(string: "https://learning-os.example")!)
        ))

        do {
            try await retry.value
            XCTFail("Expected conflict")
        } catch let APIClientError.rejected(status, _) {
            XCTAssertEqual(status, 409)
        }
        XCTAssertEqual(mutation.kind, "draftCommit")
        XCTAssertNil(mutation.lastError)
        XCTAssertEqual(outbox.drafts.first?.committedCardId, clientCardID)
    }

    @MainActor
    func testConflictLookupDoesNotReuseFetchStartedBeforeConflict() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000DN"
        let clientCardID = "01J0000000000000000000000CN"
        let otherCardID = "01J0000000000000000000000FN"
        let stale = makeDraft(id: draftID)
        let committed = makeDraft(id: draftID, committedCardID: otherCardID)
        let staleData = try StorageCodec.encoder.encode(stale)
        let committedData = try StorageCodec.encoder.encode(committed)
        let detailRequestCounter = LockedCounter()
        let initialFetch = LockedDeferredResponse()
        let conflictFetch = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            if request.httpMethod == "POST" {
                completion(.success(Self.response(
                    status: 409,
                    data: Data(#"{"message":"already committed"}"#.utf8),
                    request: request
                )))
            } else if detailRequestCounter.next() == 1 {
                initialFetch.hold(completion)
            } else {
                conflictFetch.hold(completion)
            }
        }
        let outbox = ManualDraftOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)

        let olderFetch = Task { try await outbox.fetch(id: draftID) }
        for _ in 0..<100 where !initialFetch.hasPendingResponse {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(initialFetch.hasPendingResponse)
        let mutation = try outbox.stageCommit(draftID: draftID, cardID: clientCardID)
        let retry = Task { try await outbox.retryPendingCommits { _ in } }
        for _ in 0..<100 where !conflictFetch.hasPendingResponse {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(conflictFetch.hasPendingResponse)
        XCTAssertEqual(detailRequestCounter.current, 2)
        conflictFetch.succeed(with: Self.response(
            status: 200,
            data: committedData,
            request: URLRequest(url: URL(string: "https://learning-os.example")!)
        ))

        do {
            try await retry.value
            XCTFail("Expected conflict")
        } catch let APIClientError.rejected(status, _) {
            XCTAssertEqual(status, 409)
        }
        XCTAssertEqual(mutation.kind, "draftCommitRejected")
        XCTAssertNotNil(mutation.lastError)

        initialFetch.succeed(with: Self.response(
            status: 200,
            data: staleData,
            request: URLRequest(url: URL(string: "https://learning-os.example")!)
        ))
        _ = try await olderFetch.value
        XCTAssertEqual(outbox.drafts.first?.committedCardId, otherCardID)
    }

    @MainActor
    func testCleanupFailureKeepsConfirmedCardAndRetryableMutation() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000D7"
        let cardID = "01J0000000000000000000000C7"
        let card = makeCard(id: cardID)
        let cardData = try StorageCodec.encoder.encode(card)
        let client = makeClient { request in
            if request.httpMethod == "POST" {
                return Self.response(status: 200, data: cardData, request: request)
            }
            return Self.response(
                status: 500,
                data: Data(#"{"message":"cleanup failed"}"#.utf8),
                request: request
            )
        }
        let outbox = ManualDraftOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        _ = try outbox.stageCommit(draftID: draftID, cardID: cardID)

        do {
            try await outbox.retryPendingCommits { acknowledged in
                container.mainContext.insert(LocalCardRecord(
                    card: acknowledged,
                    userID: 7,
                    queueIndex: 0,
                    payload: try StorageCodec.encoder.encode(acknowledged)
                ))
                try container.mainContext.save()
            }
            XCTFail("Expected cleanup failure")
        } catch let APIClientError.rejected(status, _) {
            XCTAssertEqual(status, 500)
        }

        let mutation = try XCTUnwrap(mutations(in: container, userID: 7).first)
        XCTAssertEqual(mutation.attemptCount, 1)
        XCTAssertNil(mutation.lastError)
        XCTAssertEqual(outbox.recoveryState(for: draftID), .cleanupPending)
    }

    @MainActor
    func testAcceptedDeleteAfterAccountSwitchCleansOldRejectedMutationOnly() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let oldDraft = makeDraft(id: "01J0000000000000000000000DA")
        let newDraft = makeDraft(id: "01J0000000000000000000000DB")
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let client = makeDeferredClient { request, completion in
            startedContinuation.yield()
            Task {
                for await _ in release {
                    completion(.success(Self.response(status: 204, request: request)))
                    return
                }
            }
        }
        let outbox = ManualDraftOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 1)
        let rejected = try outbox.stageCommit(
            draftID: oldDraft.id,
            cardID: "01J0000000000000000000000CA"
        )
        rejected.kind = "draftCommitRejected"
        try container.mainContext.save()
        outbox.replace(oldDraft)

        let deletion = Task { try await outbox.deleteDraft(id: oldDraft.id) }
        for await _ in started { break }
        outbox.activate(userID: 2)
        outbox.replace(newDraft)
        releaseContinuation.yield()

        do {
            try await deletion.value
            XCTFail("Expected stale deletion cancellation")
        } catch is CancellationError {
            // The accepted server deletion still cleans user 1 persistence.
        }
        XCTAssertTrue(try mutations(in: container, userID: 1).isEmpty)
        XCTAssertEqual(outbox.drafts.map(\.id), [newDraft.id])
    }

    @MainActor
    func testAccountSwitchLeavesOldMutationAndNewFlushIndependent() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let (oldStarted, oldStartedContinuation) = AsyncStream<Void>.makeStream()
        let (newStarted, newStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releaseOld, releaseOldContinuation) = AsyncStream<Void>.makeStream()
        let (releaseNew, releaseNewContinuation) = AsyncStream<Void>.makeStream()
        let order = LockedCounter()
        let cardData = try StorageCodec.encoder.encode(
            makeCard(id: "01J0000000000000000000000C8")
        )
        let client = makeDeferredClient { request, completion in
            if request.httpMethod == "DELETE" {
                completion(.success(Self.response(status: 204, request: request)))
                return
            }
            let isOld = order.next() == 1
            let release: AsyncStream<Void>
            if isOld {
                oldStartedContinuation.yield()
                release = releaseOld
            } else {
                newStartedContinuation.yield()
                release = releaseNew
            }
            Task {
                for await _ in release {
                    completion(.success(Self.response(
                        status: 200,
                        data: cardData,
                        request: request
                    )))
                    return
                }
            }
        }
        let outbox = ManualDraftOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 1)
        _ = try outbox.stageCommit(
            draftID: "01J0000000000000000000000D8",
            cardID: "01J0000000000000000000000C8"
        )
        let oldFlush = Task { try await outbox.retryPendingCommits { _ in } }
        for await _ in oldStarted { break }

        outbox.activate(userID: 2)
        _ = try outbox.stageCommit(
            draftID: "01J0000000000000000000000D9",
            cardID: "01J0000000000000000000000C8"
        )
        let newFlush = Task { try await outbox.retryPendingCommits { _ in } }
        for await _ in newStarted { break }

        releaseOldContinuation.yield()
        _ = try? await oldFlush.value
        releaseNewContinuation.yield()
        try await newFlush.value

        XCTAssertEqual(try mutations(in: container, userID: 1).count, 1)
        XCTAssertTrue(try mutations(in: container, userID: 2).isEmpty)
    }

    @MainActor
    func testOlderDraftFetchCannotReplaceNewerPublishedDraft() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000DE"
        let stale = makeDraft(
            id: draftID,
            cue: "stale",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let newer = makeDraft(
            id: draftID,
            cue: "newer",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let staleData = try StorageCodec.encoder.encode(stale)
        let deferredFetch = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            deferredFetch.hold(completion)
        }
        let outbox = ManualDraftOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)

        let fetch = Task { try await outbox.fetch(id: draftID) }
        for _ in 0..<100 where !deferredFetch.hasPendingResponse {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(deferredFetch.hasPendingResponse)
        outbox.replace(newer)
        deferredFetch.succeed(with: Self.response(
            status: 200,
            data: staleData,
            request: URLRequest(url: URL(string: "https://learning-os.example")!)
        ))

        let fetched = try await fetch.value
        XCTAssertEqual(fetched.prompt["cueText"]?.stringValue, "newer")
        XCTAssertEqual(outbox.drafts.first?.prompt["cueText"]?.stringValue, "newer")
    }

    @MainActor
    func testDraftFetchCannotResurrectDraftDeletedWhileRequestIsInFlight() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000DF"
        let draft = makeDraft(id: draftID)
        let draftData = try StorageCodec.encoder.encode(draft)
        let deferredFetch = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            if request.httpMethod == "DELETE" {
                completion(.success(Self.response(status: 204, request: request)))
            } else {
                deferredFetch.hold(completion)
            }
        }
        let outbox = ManualDraftOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        outbox.replace(draft)

        let fetch = Task { try await outbox.fetch(id: draftID) }
        for _ in 0..<100 where !deferredFetch.hasPendingResponse {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(deferredFetch.hasPendingResponse)
        try await outbox.deleteDraft(id: draftID)
        XCTAssertTrue(outbox.drafts.isEmpty)
        deferredFetch.succeed(with: Self.response(
            status: 200,
            data: draftData,
            request: URLRequest(url: URL(string: "https://learning-os.example")!)
        ))

        do {
            _ = try await fetch.value
            XCTFail("Expected the deleted draft fetch to be discarded")
        } catch is CancellationError {}
        XCTAssertTrue(outbox.drafts.isEmpty)
    }

    @MainActor
    func testDraftFetchCannotResurrectDraftRemovedByConcurrentRefresh() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000DG"
        let draft = makeDraft(id: draftID)
        let draftData = try StorageCodec.encoder.encode(draft)
        let deferredFetch = LockedDeferredResponse()
        let client = makeDeferredClient { _, completion in
            deferredFetch.hold(completion)
        }
        let outbox = ManualDraftOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        outbox.replace(draft)

        let fetch = Task { try await outbox.fetch(id: draftID) }
        for _ in 0..<100 where !deferredFetch.hasPendingResponse {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(deferredFetch.hasPendingResponse)
        outbox.applyFetchedDrafts([])
        XCTAssertTrue(outbox.drafts.isEmpty)
        deferredFetch.succeed(with: Self.response(
            status: 200,
            data: draftData,
            request: URLRequest(url: URL(string: "https://learning-os.example")!)
        ))

        do {
            _ = try await fetch.value
            XCTFail("Expected the removed draft fetch to be discarded")
        } catch is CancellationError {}
        XCTAssertTrue(outbox.drafts.isEmpty)
    }

    @MainActor
    func testEqualTimestampFetchCanApplyServerGeneratedFields() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000DH"
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let cached = makeDraft(id: draftID, cue: "before", updatedAt: timestamp)
        let fetched = makeDraft(id: draftID, cue: "with preview", updatedAt: timestamp)
        let fetchedData = try StorageCodec.encoder.encode(fetched)
        let client = makeClient { request in
            Self.response(status: 200, data: fetchedData, request: request)
        }
        let outbox = ManualDraftOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        outbox.replace(cached)

        let result = try await outbox.fetch(id: draftID)

        XCTAssertEqual(result.prompt["cueText"]?.stringValue, "with preview")
        XCTAssertEqual(outbox.drafts.first?.prompt["cueText"]?.stringValue, "with preview")
    }

    @MainActor
    func testListPayloadDifferenceDoesNotSuppressConcurrentDetailFetch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000DI"
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let cached = makeDraft(id: draftID, cue: "cached detail", updatedAt: timestamp)
        let listDraft = makeDraft(id: draftID, cue: "list payload", updatedAt: timestamp)
        let fetched = makeDraft(id: draftID, cue: "fresh detail", updatedAt: timestamp)
        let fetchedData = try StorageCodec.encoder.encode(fetched)
        let deferredFetch = LockedDeferredResponse()
        let client = makeDeferredClient { _, completion in
            deferredFetch.hold(completion)
        }
        let outbox = ManualDraftOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        outbox.replace(cached)

        let fetch = Task { try await outbox.fetch(id: draftID) }
        for _ in 0..<100 where !deferredFetch.hasPendingResponse {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(deferredFetch.hasPendingResponse)
        outbox.applyFetchedDrafts([listDraft])
        deferredFetch.succeed(with: Self.response(
            status: 200,
            data: fetchedData,
            request: URLRequest(url: URL(string: "https://learning-os.example")!)
        ))

        let result = try await fetch.value
        XCTAssertEqual(result.prompt["cueText"]?.stringValue, "fresh detail")
        XCTAssertEqual(outbox.drafts.first?.prompt["cueText"]?.stringValue, "fresh detail")
    }

    @MainActor
    func testNewerDetailFetchWinsOverIntermediateConcurrentRefresh() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000DL"
        let cached = makeDraft(
            id: draftID,
            cue: "cached",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let intermediate = makeDraft(
            id: draftID,
            cue: "intermediate refresh",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let fetched = makeDraft(
            id: draftID,
            cue: "newer detail",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_200)
        )
        let fetchedData = try StorageCodec.encoder.encode(fetched)
        let deferredFetch = LockedDeferredResponse()
        let client = makeDeferredClient { _, completion in
            deferredFetch.hold(completion)
        }
        let outbox = ManualDraftOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        outbox.replace(cached)

        let fetch = Task { try await outbox.fetch(id: draftID) }
        for _ in 0..<100 where !deferredFetch.hasPendingResponse {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(deferredFetch.hasPendingResponse)
        outbox.applyFetchedDrafts([intermediate])
        deferredFetch.succeed(with: Self.response(
            status: 200,
            data: fetchedData,
            request: URLRequest(url: URL(string: "https://learning-os.example")!)
        ))

        let result = try await fetch.value
        XCTAssertEqual(result.prompt["cueText"]?.stringValue, "newer detail")
        XCTAssertEqual(outbox.drafts.first?.prompt["cueText"]?.stringValue, "newer detail")
    }

    @MainActor
    func testEqualTimestampFetchCannotUndoConcurrentCommitState() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000DM"
        let cardID = "01J0000000000000000000000CM"
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = makeDraft(id: draftID, updatedAt: timestamp)
        let committed = makeDraft(
            id: draftID,
            committedCardID: cardID,
            updatedAt: timestamp
        )
        let staleData = try StorageCodec.encoder.encode(stale)
        let deferredFetch = LockedDeferredResponse()
        let client = makeDeferredClient { _, completion in
            deferredFetch.hold(completion)
        }
        let outbox = ManualDraftOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        outbox.replace(stale)

        let fetch = Task { try await outbox.fetch(id: draftID) }
        for _ in 0..<100 where !deferredFetch.hasPendingResponse {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(deferredFetch.hasPendingResponse)
        outbox.replace(committed)
        deferredFetch.succeed(with: Self.response(
            status: 200,
            data: staleData,
            request: URLRequest(url: URL(string: "https://learning-os.example")!)
        ))

        let result = try await fetch.value
        XCTAssertEqual(result.status, "committed")
        XCTAssertEqual(result.committedCardId, cardID)
        XCTAssertEqual(outbox.drafts.first?.committedCardId, cardID)
    }

    @MainActor
    func testConcurrentFetchesForSameDraftShareOneRequest() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let draftID = "01J0000000000000000000000DJ"
        let draft = makeDraft(id: draftID)
        let draftData = try StorageCodec.encoder.encode(draft)
        let requestCounter = LockedCounter()
        let deferredFetch = LockedDeferredResponse()
        let client = makeDeferredClient { _, completion in
            _ = requestCounter.next()
            deferredFetch.hold(completion)
        }
        let outbox = ManualDraftOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)

        let first = Task { try await outbox.fetch(id: draftID) }
        let second = Task { try await outbox.fetch(id: draftID) }
        for _ in 0..<100 where !deferredFetch.hasPendingResponse {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(deferredFetch.hasPendingResponse)
        XCTAssertEqual(requestCounter.current, 1)
        deferredFetch.succeed(with: Self.response(
            status: 200,
            data: draftData,
            request: URLRequest(url: URL(string: "https://learning-os.example")!)
        ))

        let results = try await (first.value, second.value)
        XCTAssertEqual(results.0, draft)
        XCTAssertEqual(results.1, draft)
        XCTAssertEqual(requestCounter.current, 1)
    }

    @MainActor
    private func makeOutbox(container: ModelContainer) -> ManualDraftOutbox {
        ManualDraftOutbox(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext
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
    private func mutations(
        in container: ModelContainer,
        userID: Int
    ) throws -> [PendingMutation] {
        try container.mainContext.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.userID == userID
                        && ($0.kind == "draftCreate"
                            || $0.kind == "draftCommit"
                            || $0.kind == "draftCommitRejected")
                },
                sortBy: [SortDescriptor(\.createdAt)]
            )
        )
    }

    private func makeCreateRequest(id: String) -> CreateStudyManualCardDraftRequest {
        CreateStudyManualCardDraftRequest(
            id: id,
            creationKind: .textRecognition,
            cardType: "recognition",
            prompt: .object(["cueText": .string("draft")]),
            answer: .object(["meaning": .string("meaning")]),
            imagePlacement: .none,
            imagePrompt: nil
        )
    }

    private func makeDraft(
        id: String,
        committedCardID: String? = nil,
        cue: String = "draft",
        updatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> StudyManualCardDraft {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return StudyManualCardDraft(
            id: id,
            status: committedCardID == nil ? "ready" : "committed",
            committedCardId: committedCardID,
            creationKind: .textRecognition,
            cardType: "recognition",
            prompt: .object(["cueText": .string(cue)]),
            answer: .object(["meaning": .string("meaning")]),
            imagePlacement: .none,
            imagePrompt: nil,
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil,
            errorMessage: nil,
            createdAt: date,
            updatedAt: updatedAt
        )
    }

    @MainActor
    private func makeCard(id: String) -> StudyCard {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return StudyCard(
            id: id,
            syncId: id,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string("card")]),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: nil,
                introducedAt: nil,
                failedAt: nil,
                queueState: "new",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: date,
            updatedAt: date
        )
    }

    private static func response(
        status: Int,
        data: Data = Data(),
        request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            data
        )
    }
}
