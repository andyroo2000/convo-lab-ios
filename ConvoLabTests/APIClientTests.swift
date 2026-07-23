import Foundation
import XCTest
@testable import ConvoLab

final class APIClientTests: XCTestCase {
    @MainActor
    func testDownloadRejectsUnsuccessfulHTTPResponse() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"message":"Missing media"}"#.utf8))
        }

        do {
            _ = try await client.download(URL(string: "https://learning-os.example/media.mp3")!)
            XCTFail("Expected unsuccessful media response to be rejected")
        } catch APIClientError.rejected(status: 404, message: _) {
            // Expected.
        }
    }

    @MainActor
    func testStudyCardMutationUsesDirectCompatibilityPayload() async throws {
        let cardJSON = """
        {
          "id": "01J00000000000000000000000",
          "noteId": null,
          "cardType": "recognition",
          "prompt": {"cueText": "犬"},
          "answer": {"meaning": "dog"},
          "state": {
            "dueAt": null,
            "introducedAt": null,
            "failedAt": null,
            "queueState": "new",
            "scheduler": null,
            "source": {}
          },
          "answerAudioSource": "missing",
          "createdAt": "2026-07-23T12:00:00.000Z",
          "updatedAt": "2026-07-23T12:00:00.000Z"
        }
        """
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(cardJSON.utf8))
        }

        let card: StudyCard = try await client.request(
            "/api/study/cards",
            method: "POST",
            body: CreateStudyCardRequest(
                id: "01J00000000000000000000000",
                cardType: "recognition",
                prompt: .object(["cueText": .string("犬")]),
                answer: .object(["meaning": .string("dog")])
            )
        )

        XCTAssertEqual(card.promptText, "犬")
        XCTAssertEqual(card.answerText, "dog")
    }

    @MainActor
    func testDownloadDoesNotForwardBearerTokenToThirdPartyOrigin() async throws {
        let client = makeClient { request in
            let status = request.value(forHTTPHeaderField: "Authorization") == nil ? 200 : 418
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("audio".utf8)
            )
        }
        client.setAccessToken("secret-mobile-token")

        _ = try await client.download(URL(string: "https://cdn.example/audio.mp3")!)
    }

    @MainActor
    private func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
