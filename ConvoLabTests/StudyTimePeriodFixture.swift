import Foundation
import XCTest
@testable import ConvoLab

nonisolated struct StudyTimePeriodFixture {
    let calendar: Calendar
    let now: Date

    init(timezone: String = "America/New_York", now: String = "2026-10-18T16:00:00Z") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone)!
        calendar.firstWeekday = 2
        self.calendar = calendar
        self.now = ISO8601DateFormatter().date(from: now)!
    }

    func date(_ value: String) -> Date {
        formatter.date(from: value)!
    }

    func anchor(_ date: Date) -> String { formatter.string(from: date) }

    private var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    @MainActor func response(anchor: Date) -> StudyTimeAnalytics {
        StudyTimeAnalytics(
            generatedAt: now, anchorDate: self.anchor(anchor), timezone: calendar.timeZone.identifier,
            ranges: StudyTimeRange.allCases.map { range($0, anchor: anchor) }
        )
    }

    @MainActor private func range(_ key: StudyTimeRange, anchor: Date) -> StudyTimeAnalyticsRange {
        let bounds = calendar.dateInterval(of: periodUnit(key), for: key == .all ? now : anchor)!
        let buckets = buckets(in: bounds, unit: bucketUnit(key))
        let categories = buckets.reduce(into: [String: Int]()) { result, bucket in
            for (category, value) in bucket.categories { result[category, default: 0] += value }
        }
        return .init(key: key, startsAt: bounds.start, endsAt: bounds.end,
                     totalMs: categories.values.reduce(0, +), categories: categories, buckets: buckets)
    }

    private func periodUnit(_ key: StudyTimeRange) -> Calendar.Component {
        switch key {
        case .today: .day
        case .week: .weekOfYear
        case .month: .month
        case .year, .all: .year
        }
    }

    private func bucketUnit(_ key: StudyTimeRange) -> Calendar.Component {
        switch key {
        case .today: .hour
        case .week, .month: .day
        case .year, .all: .month
        }
    }

    private func buckets(in bounds: DateInterval, unit: Calendar.Component) -> [StudyTimeAnalyticsBucket] {
        var buckets: [StudyTimeAnalyticsBucket] = []
        var start = bounds.start
        while start < bounds.end {
            let end = calendar.date(byAdding: unit, value: 1, to: start)!
            let categories = start < now ? ["review": 60_001, "listen": 120_002] : [:]
            buckets.append(.init(startsAt: start, endsAt: end,
                                 totalMs: categories.values.reduce(0, +), categories: categories))
            start = end
        }
        return buckets
    }
}

@MainActor
final class StudyTimePeriodHarness {
    let fixture: StudyTimePeriodFixture
    let requests = LockedCounter()
    let controller: StudyTimeInsightsController

    init(delay: Duration = .zero, fixture: StudyTimePeriodFixture = .init()) {
        self.fixture = fixture
        let requests = requests
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = { request, completion in
            _ = requests.next()
            let anchor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "anchorDate" }?.value ?? fixture.anchor(fixture.now)
            Task {
                try? await Task.sleep(for: delay)
                let response = await fixture.response(anchor: fixture.date(anchor))
                completion(Result {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                            httpVersion: nil, headerFields: nil)!,
                            try encoder.encode(response))
                })
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://period.test")!,
                            session: URLSession(configuration: configuration))
        controller = StudyTimeInsightsController(api: api, snapshotCache: EmptyStudyTimeSnapshotCache(),
                                                now: { fixture.now }, timeZone: { fixture.calendar.timeZone })
        controller.activate(userID: 42)
    }

    nonisolated deinit {}
}
