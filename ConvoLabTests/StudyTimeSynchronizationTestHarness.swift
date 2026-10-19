import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeSynchronizationTestHarness {
    let container: ModelContainer
    let transport = StudyTimeSynchronizationTestTransport()
    let periods = StudyTimePeriodFixture()
    let api: APIClient
    let repository: StudyTimeSessionMutationRepository
    let insights: StudyTimeInsightsController
    let coordinator: StudyTimeSynchronizationCoordinator

    init(calendar: (any StudyCalendarProviding)? = nil) throws {
        container = try StudyTimePersistence.makeContainer(inMemory: true)
        api = transport.makeClient()
        api.setAccessToken("account-a-token")
        repository = StudyTimeSessionMutationRepository(api: api, context: container.mainContext,
                                                        storageMode: .persistent, contextSaver: nil, calendar: calendar)
        let now = periods.now
        insights = StudyTimeInsightsController(api: api, snapshotCache: EmptyStudyTimeSnapshotCache(),
                                               now: { now }, timeZone: { TimeZone(identifier: "America/New_York")! })
        coordinator = StudyTimeSynchronizationCoordinator(api: api, repository: repository, insights: insights)
        activate(42)
    }

    nonisolated deinit {}

    func activate(_ userID: Int) {
        coordinator.activate(userID: userID)
        insights.activate(userID: userID)
    }

    @discardableResult
    func seed(_ identifier: String = "pending-session", pending: Bool = true) throws -> LocalStudyActivitySession {
        let record = LocalStudyActivitySession(session: makeSession(source: .manual, clientSessionId: identifier), userID: 42)
        record.syncPending = pending
        container.mainContext.insert(record)
        try container.mainContext.save()
        return record
    }

    func makeStore() -> StudyTimeStore {
        let now = periods.now
        let store = StudyTimeStore(api: api, context: container.mainContext,
                                   snapshotCache: EmptyStudyTimeSnapshotCache(), now: { now })
        store.activate(userID: 42)
        return store
    }
}

@MainActor
final class StudyTimeSynchronizationTestTransport {
    enum Route: String { case batch, history, analytics, deletion }

    private struct Pending {
        let request: URLRequest
        let completion: MockURLProtocol.DeferredCompletion
    }

    private var pending: [Route: [Pending]] = [:]
    private var waiting: [Route: [Int: XCTestExpectation]] = [:]
    nonisolated deinit {}

    func makeClient() -> APIClient {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = { [weak self] request, completion in
            Task { @MainActor in self?.receive(request, completion: completion) }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(baseURL: URL(string: "https://sync-ownership.test")!,
                         session: URLSession(configuration: configuration))
    }

    func count(_ route: Route) -> Int { pending[route, default: []].count }

    func request(_ route: Route, index: Int = 0) throws -> URLRequest {
        try item(route, index: index).request
    }

    func expecting(_ route: Route, count: Int = 1) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "\(route.rawValue) request \(count)")
        if self.count(route) >= count { expectation.fulfill() }
        else { waiting[route, default: [:]][count] = expectation }
        return expectation
    }

    func complete(_ route: Route, index: Int = 0, sessions: [StudyActivitySession] = []) throws {
        let item = try item(route, index: index)
        let data = try responseData(route, request: item.request, sessions: sessions)
        let response = HTTPURLResponse(url: item.request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        item.completion(.success((response, data)))
    }

    func fail(_ route: Route, index: Int = 0, error: Error = URLError(.notConnectedToInternet)) throws {
        try item(route, index: index).completion(.failure(error))
    }

    private func item(_ route: Route, index: Int) throws -> Pending {
        let values = pending[route, default: []]
        return try XCTUnwrap(values.indices.contains(index) ? values[index] : nil)
    }

    private func receive(_ request: URLRequest, completion: @escaping MockURLProtocol.DeferredCompletion) {
        guard let route = route(for: request) else { completion(.failure(URLError(.badURL))); return }
        pending[route, default: []].append(.init(request: request, completion: completion))
        waiting[route]?.removeValue(forKey: count(route))?.fulfill()
    }

    private func route(for request: URLRequest) -> Route? {
        if request.httpMethod == "DELETE" { return .deletion }
        switch request.url?.lastPathComponent {
        case "batch": return .batch
        case "activity-sessions": return .history
        case "activity-analytics": return .analytics
        default: return nil
        }
    }

    private func responseData(_ route: Route, request: URLRequest, sessions: [StudyActivitySession]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        switch route {
        case .batch:
            return try JSONSerialization.data(withJSONObject: StudyActivitySessionTests.batchSessions(from: request))
        case .history: return try encoder.encode(sessions)
        case .deletion: return Data()
        case .analytics: return try encoder.encode(analytics(for: request))
        }
    }

    private func analytics(for request: URLRequest) -> StudyTimeAnalytics {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let timezone = items.first { $0.name == "timezone" }?.value ?? "America/New_York"
        let fixture = StudyTimePeriodFixture(timezone: timezone)
        let anchor = items.first { $0.name == "anchorDate" }?.value ?? fixture.anchor(fixture.now)
        let response = fixture.response(anchor: fixture.date(anchor))
        let ranges = items.filter { $0.name == "ranges[]" }.compactMap(\.value)
        return .init(generatedAt: response.generatedAt, anchorDate: response.anchorDate, timezone: timezone,
                     ranges: ranges.isEmpty ? response.ranges : response.ranges.filter { ranges.contains($0.key.rawValue) })
    }
}
