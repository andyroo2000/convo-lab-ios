import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

final class CardMediaMutationServiceTests: XCTestCase {
    private struct ReconciliationFailure: Error {}

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    @MainActor
    func testAnswerAudioUsesWireShapeRefreshesCacheAndReconcilesLatestCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let current = makeCard(id: "card-a", expression: "old")
        let latest = makeCard(id: "card-a", expression: "newer")
        let audio: JSONValue = .object(["url": .string("/api/study/media/audio-a")])
        let server = replacing(current, answer: current.answer.replacingObjectValues([
            "answerAudio": audio,
            "answerAudioVoiceId": .string("voice-a"),
            "answerAudioTextOverride": .string("override"),
        ]), answerAudioSource: "generated")
        let serverData = try StorageCodec.encoder.encode(server)
        let paths = LockedRequestPaths()
        let mediaDownloads = LockedCounter()
        let client = makeClient { request in
            paths.append(request.url?.path ?? "")
            if request.url?.path.hasSuffix("/regenerate-answer-audio") == true {
                XCTAssertEqual(request.timeoutInterval, 180)
                let body = try requestBody(request)
                let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                XCTAssertEqual(payload?["answerAudioVoiceId"] as? String, "voice-a")
                XCTAssertEqual(payload?["answerAudioTextOverride"] as? String, "override")
                return Self.response(status: 200, data: serverData, request: request)
            }
            return Self.response(
                status: 200,
                data: Data(
                    (mediaDownloads.next() == 1 ? "stale-audio" : "fresh-audio").utf8
                ),
                mimeType: "audio/mpeg",
                request: request
            )
        }
        let diagnosticsSink = RecordingNativeDiagnosticsSink()
        let (service, cache) = makeService(
            container: container,
            client: client,
            diagnostics: NativeDiagnostics(sink: diagnosticsSink)
        )
        let remoteURL = URL(string: "https://learning-os.example/api/study/media/audio-a")!
        let staleURL = try await cache.download(remoteURL, category: "active-study")
        XCTAssertEqual(try String(contentsOf: staleURL, encoding: .utf8), "stale-audio")
        var reconciled: StudyCard?

        let result = try await service.regenerateAnswerAudio(
            currentCard: current,
            voiceID: " voice-a ",
            textOverride: " override ",
            latestCard: { latest },
            hasPendingWrite: { _ in true },
            onReconciled: { card, pending, _ in
                XCTAssertTrue(pending)
                reconciled = card
            }
        )

        XCTAssertEqual(paths.values, [
            "/api/study/media/audio-a",
            "/api/study/cards/card-a/regenerate-answer-audio",
            "/api/study/media/audio-a",
        ])
        XCTAssertEqual(result.card.promptText, "newer")
        XCTAssertEqual(result.card.answer["answerAudio"], audio)
        XCTAssertEqual(reconciled, result.card)
        XCTAssertEqual(try String(contentsOf: result.localURL, encoding: .utf8), "fresh-audio")
        XCTAssertEqual(diagnosticsSink.events.map(\.stage), [.began, .ended])
        XCTAssertEqual(diagnosticsSink.events.last?.operation, .generation)
        XCTAssertEqual(diagnosticsSink.events.last?.outcome, .succeeded)
    }

    @MainActor
    func testImageReconciliationPreservesNewerFieldsAndCanonicalLocalID() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let current = makeCard(id: "client-id", expression: "old")
        let latest = makeCard(id: "canonical-id", expression: "newer")
        let image: JSONValue = .object(["url": .string("/api/study/media/image-a")])
        let server = replacing(
            current,
            id: "server-alias",
            answer: current.answer.replacingObjectValues(["answerImage": image])
        )
        let data = try StorageCodec.encoder.encode(server)
        let client = makeClient { request in
            if request.url?.path.hasSuffix("/regenerate-image") == true {
                let payload = try JSONSerialization.jsonObject(
                    with: try requestBody(request)
                ) as? [String: Any]
                XCTAssertEqual(payload?["imagePrompt"] as? String, "office")
                XCTAssertEqual(payload?["imageRole"] as? String, "answer")
                return Self.response(status: 200, data: data, request: request)
            }
            return Self.response(status: 200, data: Data("image".utf8), request: request)
        }
        let (service, _) = makeService(container: container, client: client)

        let result = try await service.regenerateImage(
            currentCard: current,
            prompt: " office ",
            placement: .answer,
            latestCard: { latest },
            hasPendingWrite: { _ in false },
            onReconciled: { _, _, _ in }
        )

        XCTAssertEqual(result.card.id, latest.id)
        XCTAssertEqual(result.card.promptText, "newer")
        XCTAssertEqual(result.card.answer["answerImage"], image)
        XCTAssertEqual(result.card.prompt["cueImage"], .null)
    }

    @MainActor
    func testUploadUsesMultipartContractAndReconcilesImage() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "card-upload", expression: "upload")
        let image: JSONValue = .object(["url": .string("/api/study/media/uploaded")])
        let server = replacing(
            card,
            prompt: card.prompt.replacingObjectValues(["cueImage": image])
        )
        let data = try StorageCodec.encoder.encode(server)
        let client = makeClient { request in
            if request.url?.path.hasSuffix("/image") == true {
                XCTAssertEqual(request.timeoutInterval, 120)
                let body = String(
                    data: try requestBody(request),
                    encoding: .utf8
                ) ?? ""
                XCTAssertTrue(body.contains("name=\"imageRole\""))
                XCTAssertTrue(body.contains("prompt"))
                XCTAssertTrue(body.contains("filename=\"iphone-photo.jpg\""))
                XCTAssertTrue(body.contains("image/jpeg"))
                XCTAssertTrue(body.contains("jpeg-bytes"))
                return Self.response(status: 200, data: data, request: request)
            }
            return Self.response(status: 200, data: Data("uploaded".utf8), request: request)
        }
        let diagnosticsSink = RecordingNativeDiagnosticsSink()
        let (service, _) = makeService(
            container: container,
            client: client,
            diagnostics: NativeDiagnostics(sink: diagnosticsSink)
        )

        let result = try await service.uploadImage(
            currentCard: card,
            jpegData: Data("jpeg-bytes".utf8),
            placement: .prompt,
            latestCard: { card },
            hasPendingWrite: { _ in false },
            onReconciled: { _, _, _ in }
        )

        XCTAssertEqual(result.card.prompt["cueImage"], image)
        XCTAssertEqual(diagnosticsSink.events.map(\.stage), [.began, .ended])
        XCTAssertEqual(diagnosticsSink.events.last?.operation, .mediaUpload)
        XCTAssertEqual(diagnosticsSink.events.last?.outcome, .succeeded)
    }

    @MainActor
    func testUploadReconciliationFailureEmitsPairedFailedDiagnostics() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "card-upload-failure", expression: "upload")
        let image: JSONValue = .object(["url": .string("/api/study/media/uploaded-failure")])
        let server = replacing(
            card,
            prompt: card.prompt.replacingObjectValues(["cueImage": image])
        )
        let data = try StorageCodec.encoder.encode(server)
        let client = makeClient { request in
            if request.url?.path.hasSuffix("/image") == true {
                return Self.response(status: 200, data: data, request: request)
            }
            return Self.response(status: 200, data: Data("uploaded".utf8), request: request)
        }
        let diagnosticsSink = RecordingNativeDiagnosticsSink()
        let (service, _) = makeService(
            container: container,
            client: client,
            diagnostics: NativeDiagnostics(sink: diagnosticsSink)
        )

        do {
            _ = try await service.uploadImage(
                currentCard: card,
                jpegData: Data("jpeg-bytes".utf8),
                placement: .prompt,
                latestCard: { card },
                hasPendingWrite: { _ in false },
                onReconciled: { _, _, _ in throw ReconciliationFailure() }
            )
            XCTFail("Expected reconciliation failure")
        } catch is ReconciliationFailure {}

        XCTAssertEqual(diagnosticsSink.events.map(\.stage), [.began, .ended])
        XCTAssertEqual(diagnosticsSink.events.last?.operation, .mediaUpload)
        XCTAssertEqual(diagnosticsSink.events.last?.outcome, .failed)
    }

    @MainActor
    func testMissingAndMismatchedMediaAreRejectedBeforeCacheMutation() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "card-errors", expression: "errors")
        let responses = LockedCounter()
        let mismatched = replacing(
            card,
            prompt: card.prompt.replacingObjectValues([
                "cueImage": .object(["url": .string("/api/study/media/front")]),
            ]),
            answer: card.answer.replacingObjectValues([
                "answerImage": .object(["url": .string("/api/study/media/back")]),
            ])
        )
        let missingAudioData = try StorageCodec.encoder.encode(card)
        let mismatchedData = try StorageCodec.encoder.encode(mismatched)
        let client = makeClient { request in
            let data = responses.next() == 1 ? missingAudioData : mismatchedData
            return Self.response(status: 200, data: data, request: request)
        }
        let (service, _) = makeService(container: container, client: client)

        do {
            _ = try await service.regenerateAnswerAudio(
                currentCard: card,
                voiceID: "",
                textOverride: "",
                latestCard: { card },
                hasPendingWrite: { _ in false },
                onReconciled: { _, _, _ in }
            )
            XCTFail("Expected missing audio")
        } catch is MissingGeneratedCardAudioError {}
        do {
            _ = try await service.regenerateImage(
                currentCard: card,
                prompt: "image",
                placement: .both,
                latestCard: { card },
                hasPendingWrite: { _ in false },
                onReconciled: { _, _, _ in }
            )
            XCTFail("Expected mismatched images")
        } catch is MismatchedGeneratedCardImagesError {}
        XCTAssertEqual(responses.current, 2)
    }

    @MainActor
    func testImageInputValidationMakesNoRequest() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "card-invalid", expression: "invalid")
        let requests = LockedCounter()
        let client = makeClient { request in
            _ = requests.next()
            return Self.response(status: 500, request: request)
        }
        let (service, _) = makeService(container: container, client: client)

        do {
            _ = try await service.regenerateImage(
                currentCard: card,
                prompt: "   ",
                placement: .prompt,
                latestCard: { card },
                hasPendingWrite: { _ in false },
                onReconciled: { _, _, _ in }
            )
            XCTFail("Expected invalid prompt")
        } catch is InvalidCardImagePromptError {}
        do {
            _ = try await service.regenerateImage(
                currentCard: card,
                prompt: "valid",
                placement: .none,
                latestCard: { card },
                hasPendingWrite: { _ in false },
                onReconciled: { _, _, _ in }
            )
            XCTFail("Expected invalid placement")
        } catch is InvalidCardImagePlacementError {}
        XCTAssertEqual(requests.current, 0)
    }

    @MainActor
    func testTransientAndPermanentAPIErrorsPassThroughWithoutReconciliation() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "card-api-errors", expression: "errors")
        let attempts = LockedCounter()
        let client = makeClient { request in
            if attempts.next() == 1 { throw URLError(.timedOut) }
            return Self.response(
                status: 422,
                data: Data(#"{"message":"invalid media"}"#.utf8),
                request: request
            )
        }
        let diagnosticsSink = RecordingNativeDiagnosticsSink()
        let (service, _) = makeService(
            container: container,
            client: client,
            diagnostics: NativeDiagnostics(sink: diagnosticsSink)
        )
        let reconcileCount = LockedCounter()
        let operation = {
            try await service.regenerateAnswerAudio(
                currentCard: card,
                voiceID: "",
                textOverride: "",
                latestCard: { card },
                hasPendingWrite: { _ in false },
                onReconciled: { _, _, _ in _ = reconcileCount.next() }
            )
        }
        do { _ = try await operation(); XCTFail("Expected timeout") }
        catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        do { _ = try await operation(); XCTFail("Expected rejection") }
        catch let APIClientError.rejected(status, _) { XCTAssertEqual(status, 422) }
        XCTAssertEqual(reconcileCount.current, 0)
        XCTAssertEqual(
            diagnosticsSink.events.map(\.stage),
            [.began, .ended, .began, .ended]
        )
        XCTAssertEqual(
            diagnosticsSink.events.compactMap(\.outcome),
            [.failed, .failed]
        )
    }

    @MainActor
    func testAccountSwitchRejectsStaleResponseBeforeCacheAndReconciliation() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "card-stale", expression: "stale")
        let audio: JSONValue = .object(["url": .string("/api/study/media/stale")])
        let server = replacing(
            card,
            answer: card.answer.replacingObjectValues(["answerAudio": audio])
        )
        let serverData = try StorageCodec.encoder.encode(server)
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let client = makeDeferredClient { request, completion in
            startedContinuation.yield()
            Task {
                for await _ in release {
                    completion(.success(Self.response(
                        status: 200,
                        data: serverData,
                        request: request
                    )))
                    return
                }
            }
        }
        let (service, cache) = makeService(container: container, client: client)
        let reconciled = LockedCounter()
        let operation = Task {
            try await service.regenerateAnswerAudio(
                currentCard: card,
                voiceID: "",
                textOverride: "",
                latestCard: { card },
                hasPendingWrite: { _ in false },
                onReconciled: { _, _, _ in _ = reconciled.next() }
            )
        }
        for await _ in started { break }
        service.activate(userID: 2)
        cache.activate(userID: 2)
        releaseContinuation.yield()

        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertEqual(reconciled.current, 0)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<CachedMediaRecord>()).isEmpty
        )
    }

    @MainActor
    func testOlderAnswerAudioRegenerationCannotReplaceNewerCompletion() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "card-audio-race", expression: "race")
        let oldAudio: JSONValue = .object([
            "url": .string("/api/study/media/old-audio"),
        ])
        let newAudio: JSONValue = .object([
            "url": .string("/api/study/media/new-audio"),
        ])
        let oldServer = replacing(
            card,
            answer: card.answer.replacingObjectValues([
                "answerAudio": oldAudio,
                "answerAudioVoiceId": .string("old-voice"),
            ]),
            answerAudioSource: "generated"
        )
        let newServer = replacing(
            oldServer,
            answer: oldServer.answer.replacingObjectValues([
                "answerAudio": newAudio,
                "answerAudioVoiceId": .string("new-voice"),
            ]),
            answerAudioSource: "generated"
        )
        let oldData = try StorageCodec.encoder.encode(oldServer)
        let newData = try StorageCodec.encoder.encode(newServer)
        let deferredOld = LockedDeferredResponse()
        let regenerationRequests = LockedCounter()
        let client = makeDeferredClient { request, completion in
            if request.url?.path.hasSuffix("/regenerate-answer-audio") == true {
                if regenerationRequests.next() == 1 {
                    deferredOld.hold(completion)
                } else {
                    completion(.success(Self.response(
                        status: 200,
                        data: newData,
                        request: request
                    )))
                }
                return
            }
            completion(.success(Self.response(
                status: 200,
                data: Data("audio".utf8),
                mimeType: "audio/mpeg",
                request: request
            )))
        }
        let (service, _) = makeService(container: container, client: client)
        var latest = card
        let oldRegeneration = Task {
            try await service.regenerateAnswerAudio(
                currentCard: card,
                voiceID: "old-voice",
                textOverride: "",
                latestCard: { latest },
                hasPendingWrite: { _ in false },
                onReconciled: { updated, _, _ in latest = updated }
            )
        }
        for _ in 0..<100 where !deferredOld.hasPendingResponse {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(deferredOld.hasPendingResponse)

        _ = try await service.regenerateAnswerAudio(
            currentCard: card,
            voiceID: "new-voice",
            textOverride: "",
            latestCard: { latest },
            hasPendingWrite: { _ in false },
            onReconciled: { updated, _, _ in latest = updated }
        )
        XCTAssertEqual(latest.answer["answerAudio"], newAudio)
        deferredOld.succeed(with: Self.response(
            status: 200,
            data: oldData,
            request: URLRequest(url: URL(string: "https://learning-os.example")!)
        ))
        do {
            _ = try await oldRegeneration.value
            XCTFail("Expected the older regeneration to be superseded")
        } catch is CancellationError {}

        XCTAssertEqual(latest.answer["answerAudio"], newAudio)
        XCTAssertEqual(latest.answer["answerAudioVoiceId"]?.stringValue, "new-voice")
    }

    @MainActor
    private func makeService(
        container: ModelContainer,
        client: APIClient,
        diagnostics: NativeDiagnostics = .shared
    ) -> (CardMediaMutationService, MediaCache) {
        let cache = MediaCache(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            diagnostics: diagnostics
        )
        let service = CardMediaMutationService(
            api: client,
            mediaCache: cache,
            diagnostics: diagnostics
        )
        service.activate(userID: 1)
        return (service, cache)
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
    private func makeCard(id: String, expression: String) -> StudyCard {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return StudyCard(
            id: id,
            syncId: id,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string(expression)]),
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

    @MainActor
    private func replacing(
        _ card: StudyCard,
        id: String? = nil,
        prompt: JSONValue? = nil,
        answer: JSONValue? = nil,
        answerAudioSource: String? = nil
    ) -> StudyCard {
        StudyCard(
            id: id ?? card.id,
            syncId: id ?? card.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: prompt ?? card.prompt,
            answer: answer ?? card.answer,
            state: card.state,
            answerAudioSource: answerAudioSource ?? card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: card.updatedAt.addingTimeInterval(1)
        )
    }

    private static func response(
        status: Int,
        data: Data = Data(),
        mimeType: String = "application/json",
        request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": mimeType]
            )!,
            data
        )
    }
}
