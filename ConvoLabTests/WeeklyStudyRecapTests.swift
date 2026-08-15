import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class WeeklyStudyRecapTests: XCTestCase {
    private static var retainedContainers: [ModelContainer] = []

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    func testLiveServiceUsesFlatMondayRecapContract() async throws {
        let api = makeClient { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/api/study/weekly-recap")
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertTrue(query.contains(URLQueryItem(name: "timezone", value: "America/New_York")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "weekStartsOn", value: "2")))
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Self.fixtureData)
        }

        let recap = try await LiveWeeklyStudyRecapService(api: api).recap(
            timeZone: "America/New_York", weekStartsOn: 2
        )

        XCTAssertEqual(recap.week.totalMs, 9_000_000)
        XCTAssertEqual(recap.week.categories.duration(for: .listen), 1_800_000)
        XCTAssertEqual(recap.week.bestDay?.date, "2026-08-10")
        XCTAssertEqual(recap.previousWeek.recallRate, 0.89)
    }

    func testStoreLoadsRecapWithRequestedTimeZone() async throws {
        let service = TestWeeklyStudyRecapService(value: try Self.fixture())
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        Self.retainedContainers.append(container)
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.unsupportedURL) },
            context: container.mainContext,
            weeklyRecapService: service
        )
        store.activate(userID: 42)

        await store.loadWeeklyRecap(timeZone: "America/New_York")

        XCTAssertEqual(store.weeklyRecap?.week.reviewCount, 123)
        XCTAssertEqual(service.requests, [.init(timeZone: "America/New_York", weekStartsOn: 2)])
        XCTAssertFalse(store.weeklyRecapIsLoading)
        XCTAssertNil(store.weeklyRecapErrorMessage)
    }

    func testStoreIgnoresRecapFromPreviouslyActiveUser() async throws {
        let started = expectation(description: "recap request started")
        let service = DeferredWeeklyStudyRecapService(started: started)
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        Self.retainedContainers.append(container)
        let store = StudyTimeStore(
            api: makeClient { _ in throw URLError(.unsupportedURL) },
            context: container.mainContext,
            weeklyRecapService: service
        )
        store.activate(userID: 41)
        let load = Task { await store.loadWeeklyRecap(timeZone: "America/New_York") }
        await fulfillment(of: [started], timeout: 1)

        store.activate(userID: 42)
        service.succeed(with: try Self.fixture())
        await load.value

        XCTAssertNil(store.weeklyRecap)
        XCTAssertFalse(store.weeklyRecapIsLoading)
        XCTAssertNil(store.weeklyRecapErrorMessage)
    }

    func testPresentationHandlesLocalDatesUntimedProgressAndZeroBaseline() throws {
        let recap = try Self.fixture()
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        XCTAssertEqual(
            WeeklyStudyRecapPresentation.bestDayTitle("2026-08-10", timeZone: timeZone),
            "Monday, Aug 10"
        )
        let untimed = WeeklyStudyRecapWeek(
            startsAt: recap.week.startsAt,
            endsAt: recap.week.endsAt,
            totalMs: 0,
            activeDays: 1,
            reviewCount: 3,
            recallRate: nil,
            newCardsIntroduced: 2,
            bestDay: nil,
            categories: .init(review: 0, listen: 0, create: 0, immerse: 0, conversation: 0, wanikani: 0)
        )
        XCTAssertFalse(WeeklyStudyRecapPresentation.isEmpty(untimed))
        XCTAssertEqual(WeeklyStudyRecapPresentation.headline(for: untimed), "Progress worth keeping")
        XCTAssertEqual(WeeklyStudyRecapPresentation.timeChange(60_000, 0), "New baseline")
        XCTAssertEqual(WeeklyStudyRecapPresentation.timeChange(0, 0), "No change")
    }

    private func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(baseURL: URL(string: "https://example.test")!, session: URLSession(configuration: configuration))
    }

    private static func fixture() throws -> WeeklyStudyRecap {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WeeklyStudyRecap.self, from: fixtureData)
    }

    nonisolated private static let fixtureData = Data(#"""
    {
      "generatedAt":"2026-08-17T12:00:00Z",
      "week":{"startsAt":"2026-08-10T04:00:00Z","endsAt":"2026-08-17T04:00:00Z","totalMs":9000000,"activeDays":5,"reviewCount":123,"recallRate":0.94,"newCardsIntroduced":18,"bestDay":{"date":"2026-08-10","totalMs":2400000},"categories":{"review":3600000,"listen":1800000,"create":600000,"immerse":900000,"conversation":900000,"wanikani":1200000}},
      "previousWeek":{"totalMs":7200000,"activeDays":4,"reviewCount":100,"recallRate":0.89,"newCardsIntroduced":12}
    }
    """#.utf8)
}

@MainActor
private final class TestWeeklyStudyRecapService: WeeklyStudyRecapServing {
    struct Request: Equatable { let timeZone: String; let weekStartsOn: Int }
    let value: WeeklyStudyRecap
    private(set) var requests: [Request] = []

    init(value: WeeklyStudyRecap) { self.value = value }

    func recap(timeZone: String, weekStartsOn: Int) async throws -> WeeklyStudyRecap {
        requests.append(.init(timeZone: timeZone, weekStartsOn: weekStartsOn))
        return value
    }
}

@MainActor
private final class DeferredWeeklyStudyRecapService: WeeklyStudyRecapServing {
    private let started: XCTestExpectation
    private var continuation: CheckedContinuation<WeeklyStudyRecap, any Error>?

    init(started: XCTestExpectation) { self.started = started }

    func recap(timeZone: String, weekStartsOn: Int) async throws -> WeeklyStudyRecap {
        started.fulfill()
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func succeed(with recap: WeeklyStudyRecap) {
        continuation?.resume(returning: recap)
        continuation = nil
    }
}
