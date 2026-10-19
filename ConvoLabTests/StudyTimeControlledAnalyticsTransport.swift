import Foundation
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeControlledAnalyticsTransport {
    private struct Pending {
        let request: URLRequest
        let completion: MockURLProtocol.DeferredCompletion
    }

    private var pending: [Pending] = []
    private var expectations: [Int: XCTestExpectation] = [:]
    var count: Int { pending.count }

    nonisolated deinit {}

    func makeController(
        timeZone: @escaping () -> TimeZone = { TimeZone(identifier: "America/New_York")! },
        now: @escaping () -> Date = { .now }, snapshotCache: (any StudyTimeSnapshotCaching)? = nil
    )
        -> StudyTimeInsightsController {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = { [weak self] request, completion in
            Task { @MainActor in
                guard let self else { return }
                self.pending.append(.init(request: request, completion: completion))
                self.expectations.removeValue(forKey: self.pending.count)?.fulfill()
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://controlled-period.test")!,
                            session: URLSession(configuration: configuration))
        let controller = StudyTimeInsightsController(api: api, snapshotCache: snapshotCache ?? EmptyStudyTimeSnapshotCache(),
                                                    now: now, timeZone: timeZone)
        controller.activate(userID: 42)
        return controller
    }

    func expecting(_ count: Int) -> XCTestExpectation {
        let result = XCTestExpectation(description: "Analytics request \(count) started")
        if pending.count >= count { result.fulfill() } else { expectations[count] = result }
        return result
    }

    func complete(_ index: Int, fixture: StudyTimePeriodFixture = .init(), error: Error? = nil) throws {
        let pending = pending[index]
        if let error {
            pending.completion(.failure(error))
            return
        }
        let url = pending.request.url!
        let anchor = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "anchorDate" }!.value!
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        pending.completion(.success((HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                                     try encoder.encode(fixture.response(anchor: fixture.date(anchor!))))))
    }
}
