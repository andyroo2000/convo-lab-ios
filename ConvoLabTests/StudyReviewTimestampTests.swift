import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class StudyReviewTimestampTests: XCTestCase {
    func testCanonicalTimestampTruncatesPositiveAndPreEpochInstants() throws {
        XCTAssertEqual(
            ISO8601Milliseconds.string(
                from: Date(timeIntervalSince1970: 1_800_000_000.789_999)
            ),
            "2027-01-15T08:00:00.789Z"
        )
        XCTAssertEqual(
            ISO8601Milliseconds.string(
                from: Date(timeIntervalSince1970: -0.876_001)
            ),
            "1969-12-31T23:59:59.123Z"
        )
    }

    func testDecoderAcceptsLegacyWholeSecondTimestamp() throws {
        let decoded = try StorageCodec.decoder.decode(
            LegacyTimestamp.self,
            from: Data(#"{"reviewed_at":"2027-01-15T08:00:00Z"}"#.utf8)
        )

        XCTAssertEqual(decoded.reviewedAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testReviewUsesSameCanonicalMillisecondsLocallyInOutboxAndOnWire() async throws {
        let capturedBody = LockedReviewRequestBody()
        let client = makeClient { request in
            capturedBody.set(try requestBody(request))
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
        let container = try Persistence.makeContainer(inMemory: true)
        let outbox = ReviewEventOutbox(api: client, context: container.mainContext)
        let service = StudyReviewRecordingService(
            context: container.mainContext,
            reviewOutbox: outbox,
            reviewProjection: { card, rating, reviewedAt in
                try card.applyingReview(rating, at: reviewedAt)
            }
        )
        outbox.activate(userID: 1)
        service.activate(userID: 1)
        let reviewedAt = Date(timeIntervalSince1970: 1_800_000_000.789_123)

        let staged = try service.stage(
            card: makeCard(),
            rating: .good,
            duration: nil,
            reviewedAt: reviewedAt,
            deviceID: "device-1",
            queueIndex: 0
        )

        let expectedTimestamp = "2027-01-15T08:00:00.789Z"
        let pending = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>()).first
        )
        let persistedPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: pending.payload) as? [String: Any]
        )
        let persistedEvent = try XCTUnwrap(persistedPayload["event"] as? [String: Any])
        XCTAssertEqual(persistedEvent["reviewed_at"] as? String, expectedTimestamp)
        XCTAssertEqual(persistedEvent["client_created_at"] as? String, expectedTimestamp)
        XCTAssertEqual(
            staged.cardAfter.state.scheduler?["last_review"],
            .string(expectedTimestamp)
        )
        let expectedDate = try XCTUnwrap(
            ISO8601Milliseconds.date(from: expectedTimestamp)
        )
        XCTAssertEqual(staged.cardAfter.updatedAt, expectedDate)
        let localRecord = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let persistedCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: localRecord.payload
        )
        XCTAssertEqual(persistedCard.updatedAt, expectedDate)
        XCTAssertEqual(
            persistedCard.state.scheduler?["last_review"],
            .string(expectedTimestamp)
        )

        try await outbox.flush()

        let requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(capturedBody.value))
                as? [String: Any]
        )
        let events = try XCTUnwrap(requestObject["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["reviewed_at"] as? String, expectedTimestamp)
        XCTAssertEqual(events.first?["client_created_at"] as? String, expectedTimestamp)
    }

    private func makeClient(
        handler: @escaping ReviewTimestampURLProtocol.Handler
    ) -> APIClient {
        let host = "review-timestamp-\(UUID().uuidString.lowercased()).example"
        ReviewTimestampURLProtocol.install(handler, forHost: host)
        addTeardownBlock {
            ReviewTimestampURLProtocol.removeHandler(forHost: host)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReviewTimestampURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://\(host)")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func makeCard() -> StudyCard {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        return StudyCard(
            id: "01J000000000000000000000TS",
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string("復習")]),
            answer: .object(["meaning": .string("review")]),
            state: .init(
                dueAt: createdAt,
                introducedAt: nil,
                failedAt: nil,
                queueState: "new",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}

private struct LegacyTimestamp: Decodable {
    let reviewedAt: Date

    enum CodingKeys: String, CodingKey {
        case reviewedAt = "reviewed_at"
    }
}

private final class LockedReviewRequestBody: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Data?

    var value: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Data) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

private final class ReviewTimestampURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlersByHost: [String: Handler] = [:]

    static func install(_ handler: @escaping Handler, forHost host: String) {
        lock.lock()
        handlersByHost[host] = handler
        lock.unlock()
    }

    static func removeHandler(forHost host: String) {
        lock.lock()
        handlersByHost.removeValue(forKey: host)
        lock.unlock()
    }

    private static func handler(forHost host: String?) -> Handler? {
        guard let host else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return handlersByHost[host]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler(forHost: request.url?.host) else {
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
