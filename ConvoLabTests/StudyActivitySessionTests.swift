import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class StudyActivitySessionTests: XCTestCase {
    func testActivitiesMapToOnePrimaryCategory() {
        XCTAssertEqual(StudyActivityKind.cardReview.category, .review)
        XCTAssertEqual(StudyActivityKind.dailyAudio.category, .review)
        XCTAssertEqual(StudyActivityKind.cardCreation.category, .create)
        XCTAssertEqual(StudyActivityKind.tv.category, .immerse)
        XCTAssertEqual(StudyActivityKind.podcast.category, .immerse)
        XCTAssertEqual(StudyActivityKind.reading.category, .immerse)
        XCTAssertEqual(StudyActivityKind.conversation.category, .immerse)
        XCTAssertEqual(StudyActivityKind.other.category, .immerse)
    }

    func testBatchEncodesRetrySafeClientIdentityAndOutputMetrics() throws {
        let session = StudyActivitySession(
            id: nil,
            clientSessionId: "018f22d2-6d38-7000-8000-000000000001",
            category: .create,
            activity: .cardCreation,
            source: .manual,
            name: "Episode cards",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            durationMs: 3_600_000,
            audioPlaybackMs: nil,
            cardsCreated: 12
        )

        let data = try JSONEncoder().encode(StudyActivityBatchRequest(sessions: [session]))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoded = try XCTUnwrap((body["sessions"] as? [[String: Any]])?.first)

        XCTAssertEqual(
            encoded["clientSessionId"] as? String,
            "018f22d2-6d38-7000-8000-000000000001"
        )
        XCTAssertEqual(encoded["category"] as? String, "create")
        XCTAssertEqual(encoded["activity"] as? String, "card_creation")
        XCTAssertEqual(encoded["cardsCreated"] as? Int, 12)
    }

    func testDeactivateFinishesAndFlushesActiveSessionBeforeClearingAccount() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/activity-sessions/batch")
            let body = try requestBody(request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let postedSession = try XCTUnwrap(
                (json["sessions"] as? [[String: Any]])?.first
            )
            XCTAssertEqual(postedSession["activity"] as? String, "card_review")
            let responseBody = try JSONSerialization.data(withJSONObject: [postedSession])
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                responseBody
            )
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        let startedAt = Date.now.addingTimeInterval(-60)
        store.activate(userID: 42)
        store.start(activity: .cardReview, source: .automatic, at: startedAt)

        await store.deactivate()

        XCTAssertNil(store.active)
        XCTAssertTrue(store.sessions.isEmpty)
        let records = try container.mainContext.fetch(
            FetchDescriptor<LocalStudyActivitySession>()
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(try XCTUnwrap(records.first).syncPending)
        XCTAssertNotNil(records.first?.endedAt)
    }

    private func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: URLSession(configuration: configuration)
        )
    }
}
