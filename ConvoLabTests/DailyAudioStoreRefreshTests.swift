import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension DailyAudioStoreTests {
    func testStaleRefreshCannotPopulateReactivatedAccount() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let now = Date.now
        let currentPractice = DailyAudioPractice(
            id: "39ac4e14-b8b0-482c-8831-a3c1cb1987e1",
            practiceDate: "2026-08-12",
            status: "ready",
            targetDurationMinutes: 30,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now,
            tracks: []
        )
        let stalePractice = DailyAudioPractice(
            id: "39ac4e14-b8b0-482c-8831-a3c1cb1987e2",
            practiceDate: "2026-08-11",
            status: "ready",
            targetDurationMinutes: 30,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now,
            tracks: []
        )
        container.mainContext.insert(LocalDailyAudioPractice(
            practice: currentPractice,
            userID: 1,
            payload: try StorageCodec.encoder.encode(currentPractice)
        ))
        try container.mainContext.save()
        let responseData = try StorageCodec.encoder.encode(DailyAudioPracticePage(
            items: [stalePractice],
            total: 1,
            limit: 14,
            nextCursor: nil
        ))
        let gate = LockedRequestGate()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/daily-audio-practice")
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
        let store = makeStore(client: client, container: container)

        let refresh = Task { await store.refresh() }
        for _ in 0..<100 where !gate.hasStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(gate.hasStarted)
        store.activate(userID: 2)
        store.activate(userID: 1)
        XCTAssertEqual(store.practices.map(\.id), [currentPractice.id])
        XCTAssertFalse(store.isLoading)
        gate.release()

        let refreshed = await refresh.value
        XCTAssertFalse(refreshed)
        XCTAssertEqual(store.practices.map(\.id), [currentPractice.id])
        XCTAssertNil(store.errorMessage)
    }

    func testInterruptedOrStaleGenerationCanBeRetried() {
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = dailyAudioPractice(
            status: "generating",
            updatedAt: now.addingTimeInterval(-60)
        )
        let stale = dailyAudioPractice(
            status: "generating",
            updatedAt: now.addingTimeInterval(-(90 * 60))
        )
        let interruptedRegeneration = dailyAudioPractice(
            status: "ready",
            updatedAt: now
        )

        XCTAssertTrue(
            DailyAudioView.canRetryGeneration(
                recent,
                startRequestWasInterrupted: true,
                relativeTo: now
            )
        )
        XCTAssertFalse(
            DailyAudioView.canRetryGeneration(
                recent,
                startRequestWasInterrupted: false,
                relativeTo: now
            )
        )
        XCTAssertTrue(
            DailyAudioView.canRetryGeneration(
                stale,
                startRequestWasInterrupted: false,
                relativeTo: now
            )
        )
        XCTAssertTrue(
            DailyAudioView.canRetryGeneration(
                interruptedRegeneration,
                startRequestWasInterrupted: true,
                relativeTo: now
            )
        )
    }

    func testGenerationPollingEmitsPairedTerminalDiagnostics() async throws {
        let (store, diagnosticsSink) = try await pollGeneration(to: "ready")
        defer { store.deactivate() }

        XCTAssertEqual(
            diagnosticsSink.events.filter { $0.operation == .generation },
            [
                .init(
                    operation: .generation,
                    stage: .began,
                    outcome: nil,
                    reason: nil,
                    itemCount: 1
                ),
                .init(
                    operation: .generation,
                    stage: .ended,
                    outcome: .succeeded,
                    reason: nil,
                    itemCount: nil
                ),
            ]
        )
    }

    func testGenerationPollingReportsBackendErrorStatusAsFailed() async throws {
        let (store, diagnosticsSink) = try await pollGeneration(to: "error")
        defer { store.deactivate() }

        XCTAssertEqual(
            diagnosticsSink.events.last,
            .init(
                operation: .generation,
                stage: .ended,
                outcome: .failed,
                reason: nil,
                itemCount: nil
            )
        )
    }

    func testCancelledCreateOffersAnActionableRetry() async throws {
        let client = makeClient { _ in
            throw URLError(.cancelled)
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = makeStore(client: client, container: container)

        await store.create()

        XCTAssertTrue(store.generationStartWasInterrupted)
        XCTAssertEqual(
            store.errorMessage,
            "Generation was interrupted. You can retry it."
        )
        XCTAssertFalse(store.isLoading)
    }

    func testCancelledRefreshDoesNotMarkHealthyGenerationForRetry() async throws {
        let client = makeClient { _ in
            throw URLError(.cancelled)
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let practice = dailyAudioPractice(
            status: "generating",
            updatedAt: .now
        )
        container.mainContext.insert(
            LocalDailyAudioPractice(
                practice: practice,
                userID: 1,
                payload: try StorageCodec.encoder.encode(practice)
            )
        )
        try container.mainContext.save()
        let store = makeStore(client: client, container: container)
        defer { store.deactivate() }

        await store.refresh()

        XCTAssertFalse(store.generationStartWasInterrupted)
        XCTAssertEqual(
            store.errorMessage,
            "Refresh was interrupted. Audio generation continues on the server."
        )
        XCTAssertFalse(store.isLoading)
    }

    func testSilentRefreshSuppressesTimeoutErrors() async throws {
        let client = makeClient { _ in
            throw URLError(.timedOut)
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = makeStore(client: client, container: container)

        let refreshed = await store.refresh(showsErrors: false)

        XCTAssertFalse(refreshed)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isLoading)
    }

    func testSilentRefreshDoesNotClearADownloadError() async throws {
        let track = dailyAudioTrack(updatedAt: .now)
        let practice = DailyAudioPractice(
            id: track.practiceId,
            practiceDate: "2026-07-30",
            status: "ready",
            targetDurationMinutes: 30,
            errorMessage: nil,
            createdAt: .now,
            updatedAt: .now,
            tracks: [track]
        )
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/plain"]
                )!,
                Data()
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        container.mainContext.insert(LocalDailyAudioPractice(
            practice: practice,
            userID: 1,
            payload: try StorageCodec.encoder.encode(practice)
        ))
        try container.mainContext.save()
        let store = makeStore(client: client, container: container)

        await store.download(practice)
        let downloadError = try XCTUnwrap(store.errorMessage)
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"items":[],"total":0,"limit":14,"nextCursor":null}"#.utf8)
            )
        }

        let refreshed = await store.refresh(showsErrors: false)

        XCTAssertTrue(refreshed)
        XCTAssertEqual(store.errorMessage, downloadError)
    }

    func testManualRefreshWaitsForInFlightSilentRefreshThenFetchesAgain() async throws {
        let requestCount = LockedCounter()
        let allowFirstRequest = DispatchSemaphore(value: 0)
        let response = Data(
            #"{"items":[],"total":0,"limit":14,"nextCursor":null}"#.utf8
        )
        let client = makeClient { request in
            if requestCount.next() == 1 {
                allowFirstRequest.wait()
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                response
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = makeStore(client: client, container: container)

        let silentRefresh = Task { await store.refresh(showsErrors: false) }
        while requestCount.current == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let manualRefresh = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(requestCount.current, 1)

        allowFirstRequest.signal()
        let silentRefreshSucceeded = await silentRefresh.value
        let manualRefreshSucceeded = await manualRefresh.value
        XCTAssertTrue(silentRefreshSucceeded)
        XCTAssertTrue(manualRefreshSucceeded)
        XCTAssertEqual(requestCount.current, 2)
    }

    func testRefreshIfNeededThrottlesRecentSuccessfulRefresh() async throws {
        let requestCount = LockedCounter()
        let client = makeClient { request in
            _ = requestCount.next()
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
                      "items": [],
                      "total": 0,
                      "limit": 14,
                      "nextCursor": null
                    }
                    """.utf8
                )
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let store = makeStore(client: client, container: container)

        await store.refreshIfNeeded(maxAge: .seconds(60))
        await store.refreshIfNeeded(maxAge: .seconds(60))

        XCTAssertEqual(requestCount.current, 1)

        await store.refreshIfNeeded(maxAge: .zero)

        XCTAssertEqual(requestCount.current, 2)
    }

    private func pollGeneration(
        to terminalStatus: String
    ) async throws -> (DailyAudioStore, RecordingNativeDiagnosticsSink) {
        let timestamp = Date(timeIntervalSince1970: 10_000)
        let generating = dailyAudioPractice(status: "generating", updatedAt: timestamp)
        let terminal = dailyAudioPractice(
            status: terminalStatus,
            updatedAt: timestamp.addingTimeInterval(30)
        )
        let generatingData = try StorageCodec.encoder.encode(generating)
        let terminalData = try StorageCodec.encoder.encode(DailyAudioPracticePage(
            items: [terminal],
            total: 1,
            limit: 14,
            nextCursor: nil
        ))
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/daily-audio-practice")
            let data = request.httpMethod == "POST" ? generatingData : terminalData
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
        let diagnosticsSink = RecordingNativeDiagnosticsSink()
        let store = makeStore(
            client: client,
            container: container,
            diagnostics: NativeDiagnostics(sink: diagnosticsSink),
            generationPollingInitialDelay: 0
        )
        await store.create()
        for _ in 0..<300 where diagnosticsSink.events.last?.stage != .ended {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (store, diagnosticsSink)
    }

}
