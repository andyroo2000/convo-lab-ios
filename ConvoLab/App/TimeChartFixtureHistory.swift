#if DEBUG
import Foundation

/// Server-shaped aggregates from four years of mixed activity, including calendar
/// conversation sessions. Raw history is deliberately not sent to a weekly chart.
nonisolated struct TimeChartFixtureHistory: Sendable {
    struct Event: Sendable {
        let date: Date
        let category: StudyActivityCategory
        let durationMS: Int
    }

    static let shared = Self()
    let now: Date
    let calendar: Calendar
    let events: [Event]

    init() {
        let now = Date.now
        self.now = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        self.calendar = calendar
        let today = calendar.startOfDay(for: now)
        events = (0..<1_460).flatMap { day in
            let start = calendar.date(byAdding: .day, value: -day, to: today)!
            return StudyActivityCategory.allCases.enumerated().flatMap { index, category in
                [9, 18].compactMap { hour -> Event? in
                    let date = calendar.date(byAdding: .hour, value: hour, to: start)!
                    guard date < now else { return nil }
                    return Event(date: date, category: category, durationMS: (3 + day % 11 + index * 2) * 60_000)
                }
            }
        }
    }

    func anchor(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func response(anchor: Date) -> StudyTimeAnalytics {
        StudyTimeAnalytics(
            generatedAt: now, anchorDate: self.anchor(anchor), timezone: calendar.timeZone.identifier,
            ranges: StudyTimeRange.allCases.map { range($0, anchor: anchor) }
        )
    }

    private func range(_ key: StudyTimeRange, anchor: Date) -> StudyTimeAnalyticsRange {
        let interval = bounds(key, anchor: anchor)
        let buckets = buckets(from: interval.start, to: interval.end, unit: bucketUnit(key))
        let categories = totals(buckets.map(\.categories))
        return StudyTimeAnalyticsRange(
            key: key, startsAt: interval.start, endsAt: interval.end,
            totalMs: categories.values.reduce(0, +), categories: categories, buckets: buckets
        )
    }

    private func bounds(_ key: StudyTimeRange, anchor: Date) -> DateInterval {
        if key == .all {
            return DateInterval(
                start: calendar.dateInterval(of: .year, for: events.last!.date)!.start,
                end: calendar.dateInterval(of: .year, for: now)!.end
            )
        }
        return calendar.dateInterval(of: periodUnit(key), for: anchor)!
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
        case .year: .month
        case .all: .year
        }
    }

    private func buckets(from start: Date, to end: Date, unit: Calendar.Component) -> [StudyTimeAnalyticsBucket] {
        var categoriesByBucket: [Date: [String: Int]] = [:]
        for event in events where event.date >= start && event.date < end {
            let bucketStart = calendar.dateInterval(of: unit, for: event.date)!.start
            categoriesByBucket[bucketStart, default: [:]][event.category.rawValue, default: 0] += event.durationMS
        }
        var result: [StudyTimeAnalyticsBucket] = []
        var date = start
        while date < end {
            let next = calendar.date(byAdding: unit, value: 1, to: date)!
            let categories = categoriesByBucket[date, default: [:]]
            result.append(StudyTimeAnalyticsBucket(
                startsAt: date, endsAt: next, totalMs: categories.values.reduce(0, +), categories: categories
            ))
            date = next
        }
        return result
    }

    private func totals(_ values: [[String: Int]]) -> [String: Int] {
        values.reduce(into: [:]) { result, categories in
            for (category, duration) in categories { result[category, default: 0] += duration }
        }
    }
}
#endif
