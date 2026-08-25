import XCTest
@testable import ConvoLab

final class StudyLearningPathRepositoryTests: XCTestCase {
    override func tearDown() {
        LearningPathMockURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor
    func testLoadsAndLinksCanonicalLearningPathWithMasteryRequirement() async throws {
        let response = Data(
            #"{"data":{"group_id":"family-1","anchor_card_id":"01AAA","stages":[{"number":1,"cards":[{"id":"01AAA","source_note_id":null,"card_type":"recognition","front_text":"聞く","back_text":"listen","prompt_json":{"cueText":"聞く"},"answer_json":{"meaning":"listen"},"variant_stage":1,"variant_status":"available","variant_unlock_requirement":null}]},{"number":2,"cards":[{"id":"01BBB","source_note_id":null,"card_type":"cloze","front_text":"よく＿。","back_text":"I listen often.","prompt_json":{"clozeDisplayText":"よく＿。"},"answer_json":{"meaning":"I listen often."},"variant_stage":2,"variant_status":"locked","variant_unlock_requirement":"master"}]}]}}"#.utf8
        )
        LearningPathMockURLProtocol.handler = { request in
            switch (request.url?.path, request.httpMethod) {
            case ("/api/cards/01AAA/learning-path", "GET"):
                break
            case ("/api/cards/01AAA/learning-path/successor", "PUT"):
                let body = try JSONSerialization.jsonObject(with: requestBody(request))
                    as? [String: String]
                XCTAssertEqual(body?["successor_card_id"], "01BBB")
                XCTAssertEqual(body?["unlock_requirement"], "master")
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
            }
            return Self.response(for: request, data: response)
        }
        let repository = StudyLearningPathRepository(api: makeAPI())

        let loaded = try await repository.learningPath(for: "01AAA")
        let linked = try await repository.linkSuccessor(
            "01BBB",
            to: "01AAA",
            requirement: .master
        )

        XCTAssertEqual(loaded, linked)
        XCTAssertEqual(loaded.groupId, "family-1")
        XCTAssertEqual(loaded.stages[0].cards[0].displayText, "聞く")
        XCTAssertEqual(loaded.stages[1].cards[0].meaning, "I listen often.")
        XCTAssertEqual(loaded.stages[1].cards[0].variantUnlockRequirement, .master)
    }

    @MainActor
    func testUnknownRequirementDecodesSafelyAndMissingRequirementRemainsNil() throws {
        let future = try StorageCodec.decoder.decode(
            StudyLearningPathUnlockRequirement.self,
            from: Data(#""future-requirement""#.utf8)
        )
        let card = try StorageCodec.decoder.decode(
            StudyLearningPathCard.self,
            from: Data(
                #"{"id":"01AAA","source_note_id":null,"card_type":"recognition","front_text":"猫","back_text":"cat","prompt_json":null,"answer_json":null,"variant_stage":1,"variant_status":"available"}"#.utf8
            )
        )

        XCTAssertEqual(future, .unknown)
        XCTAssertNil(card.variantUnlockRequirement)
        XCTAssertEqual(card.displayText, "猫")
        XCTAssertEqual(card.meaning, "cat")
    }

    @MainActor
    func testEditorDefaultsRecognitionToGuruAndTransferToMaster() {
        XCTAssertEqual(
            StudyLearningPathEditorSection.defaultRequirement(for: makeCard(type: "recognition")),
            .guru
        )
        XCTAssertEqual(
            StudyLearningPathEditorSection.defaultRequirement(for: makeCard(type: "cloze")),
            .master
        )
        XCTAssertEqual(
            StudyLearningPathEditorSection.defaultRequirement(for: makeCard(type: "production")),
            .master
        )
    }

    @MainActor
    private func makeAPI() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LearningPathMockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    private func makeCard(type: String) -> StudyCard {
        StudyCard(
            id: "01AAA",
            noteId: nil,
            cardType: type,
            prompt: .object(["cueText": .string("聞く")]),
            answer: .object(["meaning": .string("listen")]),
            state: .init(
                dueAt: nil,
                introducedAt: nil,
                failedAt: nil,
                queueState: "new",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: .now,
            updatedAt: .now
        )
    }

    private static func response(
        for request: URLRequest,
        data: Data
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

final class LearningPathMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
