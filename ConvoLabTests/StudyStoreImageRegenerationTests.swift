import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testRegenerateImagePersistsPlacementAndDownloadsForOfflineUse() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000000IM",
            expression: "会社"
        )
        try insertEditorCard(card, into: container)

        let generatedImage = Self.generatedSharedImage
        let regenerated = makeSharedImageCard(from: card)
        let responseData = try StorageCodec.encoder.encode(regenerated)
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.hasSuffix("/regenerate-image") {
                XCTAssertEqual(request.timeoutInterval, 180)
                let body = try requestBody(request)
                let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                XCTAssertEqual(payload?["imagePrompt"] as? String, "A Tokyo office.")
                XCTAssertEqual(payload?["imageRole"] as? String, "both")
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
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/webp"]
                )!,
                Data("generated-image".utf8)
            )
        }
        let store = makeEditorStore(container: container, client: client)

        let result = try await store.regenerateImage(
            for: card,
            prompt: "  A Tokyo office.  ",
            placement: .both
        )

        XCTAssertEqual(
            paths.values,
            [
                "/api/study/cards/\(card.id)/regenerate-image",
                "/api/study/media/company-image",
            ]
        )
        XCTAssertEqual(
            try String(contentsOf: result.localURL, encoding: .utf8),
            "generated-image"
        )
        XCTAssertEqual(result.card.prompt["cueImage"], generatedImage)
        XCTAssertEqual(result.card.answer["answerImage"], generatedImage)
        let stored = try persistedCard(in: container)
        XCTAssertEqual(stored.prompt["cueImage"], generatedImage)
        XCTAssertEqual(stored.answer["answerImage"], generatedImage)
    }

    @MainActor
    func testBothImageRegenerationRejectsDistinctServerImages() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000000IW",
            expression: "会社"
        )
        try insertEditorCard(card, into: container)
        let frontImage: JSONValue = .object([
            "url": .string("/api/study/media/generated-front"),
        ])
        let backImage: JSONValue = .object([
            "url": .string("/api/study/media/generated-back"),
        ])
        let serverCard = StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt.replacingObjectValues(["cueImage": frontImage]),
            answer: card.answer.replacingObjectValues(["answerImage": backImage]),
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: card.updatedAt.addingTimeInterval(1)
        )
        let responseData = try StorageCodec.encoder.encode(serverCard)
        let requestCount = LockedCounter()
        let client = makeClient { request in
            _ = requestCount.next()
            XCTAssertTrue(request.url?.path.hasSuffix("/regenerate-image") == true)
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

        do {
            _ = try await store.regenerateImage(
                for: card,
                prompt: "A company office.",
                placement: .both
            )
            XCTFail("Expected distinct images for a shared-image request to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "The server returned different front and back images for a shared-image request."
            )
        }

        XCTAssertEqual(requestCount.current, 1)
        let persisted = try persistedCard(in: container)
        XCTAssertEqual(persisted.prompt, card.prompt)
        XCTAssertEqual(persisted.answer, card.answer)
        XCTAssertEqual(persisted.state, card.state)
    }

    @MainActor
    func testRegenerateImageExplicitlyConvertsIndependentImagesToSelectedPlacement() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let baseCard = makeCard(
            id: "01J0000000000000000000000ID",
            expression: "会社"
        )
        let card = makeIndependentImageCard(from: baseCard)
        try insertEditorCard(card, into: container)

        let generatedImage: JSONValue = .object([
            "url": .string("/api/study/media/replacement"),
            "filename": .string("replacement.webp"),
        ])
        let serverCard = makeAnswerImageCard(from: card, image: generatedImage)
        let responseData = try StorageCodec.encoder.encode(serverCard)
        let client = makeImageRegenerationClient(
            responseData: responseData,
            imageData: Data("replacement-image".utf8)
        )
        let store = makeEditorStore(container: container, client: client)

        let result = try await store.regenerateImage(
            for: card,
            prompt: "A company office.",
            placement: .answer
        )

        XCTAssertEqual(result.card.prompt["cueImage"], .null)
        XCTAssertEqual(result.card.answer["answerImage"], generatedImage)
        let stored = try persistedCard(in: container)
        XCTAssertEqual(stored.prompt["cueImage"], .null)
        XCTAssertEqual(stored.answer["answerImage"], generatedImage)
    }

    @MainActor
    func testCancelledImageRegenerationStillReconcilesCompletedChanges() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000000IC",
            expression: "会社"
        )
        try insertEditorCard(card, into: container)
        let generatedImage: JSONValue = .object([
            "url": .string("/api/study/media/cancelled-image"),
            "filename": .string("cancelled.webp"),
        ])
        let regenerated = makeAnswerImageCard(from: card, image: generatedImage)
        let responseData = try StorageCodec.encoder.encode(regenerated)
        let gate = LockedRequestGate()
        let client = makeImageRegenerationClient(
            responseData: responseData,
            imageData: Data("cancelled-image".utf8),
            gate: gate
        )
        let store = makeEditorStore(container: container, client: client)

        let regeneration = Task {
            try await store.regenerateImage(
                for: card,
                prompt: "A company office.",
                placement: .answer
            )
        }
        await waitUntil { gate.hasStarted }
        regeneration.cancel()
        gate.release()
        let result = try await regeneration.value

        XCTAssertEqual(result.card.answer["answerImage"], generatedImage)
        XCTAssertEqual(try persistedCard(in: container), result.card)
        XCTAssertEqual(
            try String(contentsOf: result.localURL, encoding: .utf8),
            "cancelled-image"
        )
    }

    @MainActor
    func testImageRegenerationValidatesInputAndIgnoresQuarantinedWrite() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000000IV",
            expression: "会社"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        let pendingUpdate = PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: card.id,
            payload: try StorageCodec.encoder.encode(
                UpdateStudyCardRequest(prompt: card.prompt, answer: card.answer)
            )
        )
        pendingUpdate.lastError = "HTTP 422: Rejected"
        container.mainContext.insert(pendingUpdate)
        try container.mainContext.save()
        let requestCounter = LockedCounter()
        let client = makeClient { _ in
            _ = requestCounter.next()
            throw URLError(.badServerResponse)
        }
        let store = makeEditorStore(container: container, client: client)

        do {
            _ = try await store.regenerateImage(
                for: card,
                prompt: "   ",
                placement: .answer
            )
            XCTFail("Expected an empty image prompt to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Enter a non-empty image prompt no longer than 1,000 characters."
            )
        }
        do {
            _ = try await store.regenerateImage(
                for: card,
                prompt: "A company office.",
                placement: .none
            )
            XCTFail("Expected no-image placement to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Choose Front, Back, or Front and back before regenerating an image."
            )
        }
        do {
            _ = try await store.regenerateImage(
                for: card,
                prompt: "A company office.",
                placement: .answer
            )
            XCTFail("Expected the attempted network request to fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badServerResponse)
        }
        XCTAssertEqual(requestCounter.current, 1)
    }

    @MainActor
    private func makeSharedImageCard(from card: StudyCard) -> StudyCard {
        let signedAnswerImage: JSONValue = .object([
            "id": .string("01J00000000000000000000IMG"),
            "filename": .string("company.webp"),
            "url": .string("/api/study/media/company-image?signature=back"),
            "mediaKind": .string("image"),
            "source": .string("generated"),
        ])
        return StudyCard(
            id: card.id,
            syncId: card.id,
            noteId: nil,
            cardType: card.cardType,
            prompt: card.prompt.replacingObjectValues(["cueImage": Self.generatedSharedImage]),
            answer: card.answer.replacingObjectValues(["answerImage": signedAnswerImage]),
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: card.updatedAt.addingTimeInterval(1)
        )
    }

    @MainActor
    private func makeIndependentImageCard(from card: StudyCard) -> StudyCard {
        StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt.replacingObjectValues([
                "cueImage": .object([
                    "url": .string("/api/study/media/original-front"),
                    "filename": .string("front.webp"),
                ]),
            ]),
            answer: card.answer.replacingObjectValues([
                "answerImage": .object([
                    "url": .string("/api/study/media/original-back"),
                    "filename": .string("back.webp"),
                ]),
            ]),
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: card.updatedAt
        )
    }

    @MainActor
    private func makeAnswerImageCard(from card: StudyCard, image: JSONValue) -> StudyCard {
        StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer.replacingObjectValues(["answerImage": image]),
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: card.updatedAt.addingTimeInterval(1)
        )
    }

    @MainActor
    private func makeImageRegenerationClient(
        responseData: Data,
        imageData: Data,
        gate: LockedRequestGate? = nil
    ) -> APIClient {
        makeClient { request in
            guard request.url?.path.hasSuffix("/regenerate-image") != true else {
                return Self.response(data: responseData)
            }
            gate?.markStarted()
            gate?.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/webp"]
                )!,
                imageData
            )
        }
    }

    private static let generatedSharedImage: JSONValue = .object([
        "id": .string("01J00000000000000000000IMG"),
        "filename": .string("company.webp"),
        "url": .string("/api/study/media/company-image?signature=front"),
        "mediaKind": .string("image"),
        "source": .string("generated"),
    ])
}
