import Foundation
import XCTest
@testable import ConvoLab

final class APIClientTests: XCTestCase {
    private nonisolated(unsafe) static var retainedClients: [APIClient] = []

    private struct UploadResponse: Decodable {
        let ok: Bool
    }

    @MainActor
    func testSameOriginResourceURLAcceptsCanonicalRelativeAssetsOnly() throws {
        let client = makeClient { request in
            XCTFail("Resource URL resolution must not perform a request")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        Self.retainedClients.append(client)

        XCTAssertEqual(
            client.sameOriginResourceURL("/achievement-assets/series/badge.png")?.absoluteString,
            "https://learning-os.example/achievement-assets/series/badge.png"
        )
        XCTAssertNil(client.sameOriginResourceURL("https://example.com/tracker.png"))
    }

    @MainActor
    func testRequestWithoutResponseAcceptsEmptySuccessfulBody() async throws {
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        try await client.request(
            "/api/auth/tokens/current",
            method: "DELETE"
        )
    }

    @MainActor
    func testRequestWithoutResponseStillRejectsUnsuccessfulResponse() async throws {
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 409,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"message":"Token could not be revoked"}"#.utf8)
            )
        }

        do {
            try await client.request(
                "/api/auth/tokens/current",
                method: "DELETE"
            )
            XCTFail("Expected the unsuccessful response to be rejected")
        } catch APIClientError.rejected(status: 409, message: let message) {
            XCTAssertEqual(message, "Token could not be revoked")
        }
    }

    @MainActor
    func testTypedRequestStillDecodesNonEmptySuccessfulBody() async throws {
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"ok":true}"#.utf8)
            )
        }

        let response: UploadResponse = try await client.request("/api/status")

        XCTAssertTrue(response.ok)
    }

    @MainActor
    func testTypedRequestStillReportsEmptyBodyAsDecodingError() async throws {
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data()
            )
        }

        do {
            let _: UploadResponse = try await client.request("/api/status")
            XCTFail("Expected the empty typed response to fail decoding")
        } catch APIClientError.decoding(path: "/api/status", details: let details) {
            XCTAssertTrue(details.contains("response root"))
        }
    }

    @MainActor
    func testUploadBuildsAuthenticatedMultipartRequest() async throws {
        let photoBytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let client = makeClient { request in
            XCTAssertEqual(request.url?.absoluteString, "https://learning-os.example/api/study/cards/card-1/image")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer mobile-token"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertTrue(
                request.value(forHTTPHeaderField: "Content-Type")?
                    .hasPrefix("multipart/form-data; boundary=ConvoLab-") == true
            )

            let body = try requestBody(request)
            let bodyText = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(bodyText.contains(#"name="imageRole""#))
            XCTAssertTrue(bodyText.contains("\r\n\r\nboth\r\n"))
            XCTAssertTrue(bodyText.contains(#"name="image"; filename="iphone-photo.jpg""#))
            XCTAssertTrue(bodyText.contains("Content-Type: image/jpeg"))
            XCTAssertNotNil(body.range(of: photoBytes))

            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"ok":true}"#.utf8)
            )
        }
        client.setAccessToken("mobile-token")

        let response: UploadResponse = try await client.upload(
            "/api/study/cards/card-1/image",
            fields: ["imageRole": "both"],
            fileData: photoBytes,
            fileField: "image",
            fileName: "iphone-photo.jpg",
            mimeType: "image/jpeg"
        )

        XCTAssertTrue(response.ok)
    }

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
    func testDownloadRetriesRateLimitUsingRetryAfter() async throws {
        let requestCounter = LockedCounter()
        let client = makeClient { request in
            if requestCounter.next() == 1 {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 429,
                        httpVersion: nil,
                        headerFields: ["Retry-After": "0"]
                    )!,
                    Data()
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("audio".utf8)
            )
        }

        _ = try await client.download(
            URL(string: "https://learning-os.example/media.mp3")!
        )

        XCTAssertEqual(requestCounter.current, 2)
    }

    @MainActor
    func testStudyCardMutationUsesDirectCompatibilityPayload() async throws {
        let cardJSON = """
        {
          "id": "98f42a62-8303-410e-ad4d-5a69c55911bb",
          "syncId": "01J00000000000000000000000",
          "noteId": null,
          "revision": 4,
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
          "introductionCohortId": "01J11111111111111111111111",
          "selectionPolicy": "spaced_siblings",
          "priorityUntil": "2026-07-30T12:00:00.000Z",
          "introductionAvailableAt": "2026-07-24T12:00:00.000Z",
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
        XCTAssertEqual(card.id, "98f42a62-8303-410e-ad4d-5a69c55911bb")
        XCTAssertEqual(card.reviewCardID, "01J00000000000000000000000")
        XCTAssertEqual(card.revision, 4)
        XCTAssertEqual(card.introductionCohortId, "01J11111111111111111111111")
        XCTAssertEqual(card.selectionPolicy, "spaced_siblings")
        XCTAssertNotNil(card.priorityUntil)
        XCTAssertNotNil(card.introductionAvailableAt)

        var cachedPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(cardJSON.utf8)) as? [String: Any]
        )
        cachedPayload.removeValue(forKey: "syncId")
        cachedPayload.removeValue(forKey: "revision")
        let legacyCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: JSONSerialization.data(withJSONObject: cachedPayload)
        )
        XCTAssertNil(legacyCard.syncId)
        XCTAssertEqual(legacyCard.reviewCardID, legacyCard.id)
        XCTAssertEqual(legacyCard.revision, 0)
    }

    @MainActor
    func testLegacyPersistedCardUpdateDefaultsExpectedRevision() throws {
        let payload = Data(#"{"prompt":{"cueText":"犬"},"answer":{"meaning":"dog"}}"#.utf8)

        let request = try StorageCodec.decoder.decode(
            UpdateStudyCardRequest.self,
            from: payload
        )

        XCTAssertEqual(request.expectedRevision, 0)
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
    func testRelativeDownloadPreservesSignedQuery() async throws {
        let client = makeClient { request in
            let status = request.url?.query == "signature=abc123&expires=42" ? 200 : 403
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

        _ = try await client.download(
            URL(string: "/media/audio.mp3?signature=abc123&expires=42")!
        )
    }

    @MainActor
    func testCurrentUserDecodesIntegerBackendID() async throws {
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    #"""
                    {
                      "data": {
                        "id": 1,
                        "name": "Andrew Landry",
                        "email": "andrewlandry@gmail.com",
                        "email_verified_at": "2026-07-24T02:20:00.000000Z"
                      }
                    }
                    """#.utf8
                )
            )
        }

        let response: APIEnvelope<CurrentUser> = try await client.request("/api/me")

        XCTAssertEqual(response.data.id, 1)
        XCTAssertEqual(response.data.email, "andrewlandry@gmail.com")
    }

    @MainActor
    func testStudySessionDecodesCurrentDirectResponse() async throws {
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Self.studySessionData(wrapped: false)
            )
        }

        let response: StudySessionResponse = try await client.request(
            "/api/study/session/start",
            method: "POST"
        )

        XCTAssertEqual(response.session.overview.newCount, 1)
        XCTAssertEqual(response.session.cards.first?.promptText, "犬")
    }

    @MainActor
    func testStudySessionStillDecodesLegacyWrappedResponse() async throws {
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Self.studySessionData(wrapped: true)
            )
        }

        let response: StudySessionResponse = try await client.request(
            "/api/study/session/start",
            method: "POST"
        )

        XCTAssertEqual(response.session.overview.newCardsPerDay, 20)
        XCTAssertEqual(response.session.cards.first?.reviewCardID, "01J00000000000000000000000")
    }

    @MainActor
    func testStudySessionDecodesProductionCamelCaseOverview() async throws {
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Self.studySessionData(wrapped: false, camelCaseOverview: true)
            )
        }

        let response: StudySessionResponse = try await client.request(
            "/api/study/session/start",
            method: "POST"
        )

        XCTAssertEqual(response.session.overview.newCardsPerDay, 20)
        XCTAssertEqual(response.session.overview.newCardsAvailableToday, 1)
        XCTAssertEqual(response.session.cards.first?.reviewCardID, "01J00000000000000000000000")
    }

    private static func studySessionData(
        wrapped: Bool,
        camelCaseOverview: Bool = false
    ) -> Data {
        let overview = camelCaseOverview
            ? #"""
            {
              "dueCount": 0,
              "failedCount": 0,
              "newCount": 1,
              "reviewCount": 0,
              "newCardsPerDay": 20,
              "newCardsAvailableToday": 1
            }
            """#
            : #"""
            {
              "due_count": 0,
              "failed_count": 0,
              "new_count": 1,
              "review_count": 0,
              "new_cards_per_day": 20,
              "new_cards_available_today": 1
            }
            """#
        let session = #"""
        {
          "overview": \#(overview),
          "cards": [{
            "id": "98f42a62-8303-410e-ad4d-5a69c55911bb",
            "syncId": "01J00000000000000000000000",
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
            "createdAt": "2026-07-24T12:00:00.000Z",
            "updatedAt": "2026-07-24T12:00:00.000Z"
          }]
        }
        """#
        return Data((wrapped ? #"{"data":\#(session)}"# : session).utf8)
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
    typealias DeferredCompletion =
        @Sendable (Result<(HTTPURLResponse, Data), Error>) -> Void
    typealias DeferredHandler =
        @Sendable (URLRequest, @escaping DeferredCompletion) -> Void

    nonisolated(unsafe) static var handler: Handler?
    nonisolated(unsafe) static var deferredHandler: DeferredHandler?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let deferredHandler = Self.deferredHandler {
            deferredHandler(request) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success((response, data)):
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                case let .failure(error):
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
            return
        }
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
