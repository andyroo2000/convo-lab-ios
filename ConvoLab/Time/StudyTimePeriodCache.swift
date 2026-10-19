import Foundation

/// A range is indexed by its calendar boundary, independently of the day used
/// to request the enclosing response. Entries survive refresh as stale values.
struct StudyTimePeriodCache {
    struct Entry {
        let value: StudyTimeAnalytics
        let generation: Int
        let receivedAt: Date
    }

    private struct Record {
        let requestedAnchors: [String]
        let requestedRanges: [StudyTimeRange]?
        let entry: Entry
    }

    private struct Key: Hashable {
        let range: StudyTimeRange
        let start: Date

        init(range: StudyTimeRange, start: Date) {
            self.range = range
            self.start = range == .all ? .distantPast : start
        }
    }

    private var responses: [String: Entry] = [:]
    private var periods: [Key: Entry] = [:]
    private var records: [Record] = []

    var analytics: [String: StudyTimeAnalytics] { responses.mapValues(\.value) }
    var snapshots: [StudyTimePeriodSnapshot] {
        records.map { .init(value: $0.entry.value, receivedAt: $0.entry.receivedAt,
                            requestedRanges: $0.requestedRanges) }
    }

    mutating func insert(
        _ value: StudyTimeAnalytics, requestedAnchor: String, generation: Int, receivedAt: Date = .now,
        requestedRanges: [StudyTimeRange]? = nil
    ) {
        let entry = Entry(value: value, generation: generation, receivedAt: receivedAt)
        let key = StudyTimeAnalyticsScope.key(anchor: value.anchorDate, ranges: requestedRanges)
        let previous = records.first { Self.recordKey($0) == key }
        guard shouldReplace(previous?.entry, with: entry) else { return }
        let previousAnchors = previous?.requestedAnchors ?? []
        let anchors = previousAnchors.filter { $0 != requestedAnchor } + [requestedAnchor]
        records.removeAll { Self.recordKey($0) == key }
        records.append(.init(requestedAnchors: Array(anchors.suffix(StudyTimePeriodHistory.limit)),
                             requestedRanges: requestedRanges, entry: entry))
        records = Array(records.suffix(StudyTimePeriodHistory.limit))
        responses = [:]
        periods = [:]
        for record in records { index(record) }
    }

    private static func recordKey(_ record: Record) -> String {
        StudyTimeAnalyticsScope.key(anchor: record.entry.value.anchorDate, ranges: record.requestedRanges)
    }

    private mutating func index(_ record: Record) {
        let entry = record.entry
        indexFullResponse(record)
        for range in entry.value.ranges {
            let key = Key(range: range.key, start: range.startsAt)
            guard shouldReplace(periods[key], with: entry) else { continue }
            periods[key] = entry
        }
    }

    private mutating func indexFullResponse(_ record: Record) {
        guard record.requestedRanges == nil else { return }
        for anchor in record.requestedAnchors { responses[anchor] = record.entry }
        responses[record.entry.value.anchorDate] = record.entry
    }

    func entry(anchor: Date, range: StudyTimeRange?, context: StudyTimeAnalyticsCalendar) -> Entry? {
        guard let range else { return responses[context.anchor(anchor)] }
        guard let bounds = context.bounds(range, anchor: anchor) else { return nil }
        let direct = periods[Key(range: range, start: bounds.start)].flatMap {
            project($0, range: range, anchor: anchor, context: context)
        }
        guard range == .week,
              let derived = coveredWeek(bounds, anchor: anchor, context: context),
              shouldReplace(direct, with: derived)
        else { return direct }
        return derived
    }

    private func shouldReplace(_ old: Entry?, with new: Entry) -> Bool {
        guard let old else { return true }
        if old.generation != new.generation { return old.generation < new.generation }
        return old.value.generatedAt <= new.value.generatedAt
    }

    private func project(
        _ entry: Entry, range: StudyTimeRange, anchor: Date, context: StudyTimeAnalyticsCalendar
    ) -> Entry? {
        guard entry.value.timezone == context.timeZone.identifier,
              let value = entry.value.range(range) else { return nil }
        return selection(value, from: entry, anchor: anchor, context: context)
    }

    private func selection(
        _ range: StudyTimeAnalyticsRange, from entry: Entry, anchor: Date, context: StudyTimeAnalyticsCalendar
    ) -> Entry {
        // Only the known range belongs to this selection. In particular, a
        // derived week cannot supply the hourly chart for its anchor day.
        Entry(value: .init(generatedAt: entry.value.generatedAt, anchorDate: context.anchor(anchor),
                           timezone: entry.value.timezone, ranges: [range]), generation: entry.generation,
              receivedAt: entry.receivedAt)
    }

    private func coveredWeek(
        _ bounds: DateInterval, anchor: Date, context: StudyTimeAnalyticsCalendar
    ) -> Entry? {
        guard let monthStart = context.bounds(.month, anchor: bounds.start)?.start,
              let source = periods[Key(range: .month, start: monthStart)],
              source.value.timezone == context.timeZone.identifier,
              let month = source.value.range(.month), month.endsAt >= bounds.end
        else { return nil }
        let buckets = month.buckets.filter { $0.startsAt >= bounds.start && $0.endsAt <= bounds.end }
        guard coversWeek(buckets, bounds: bounds, calendar: context.calendar) else { return nil }
        let categories = buckets.reduce(into: [String: Int]()) { totals, bucket in
            for (category, value) in bucket.categories { totals[category, default: 0] += value }
        }
        let week = StudyTimeAnalyticsRange(
            key: .week, startsAt: bounds.start, endsAt: bounds.end,
            totalMs: buckets.reduce(0) { $0 + $1.totalMs }, categories: categories, buckets: buckets
        )
        return selection(week, from: source, anchor: anchor, context: context)
    }

    private func coversWeek(
        _ buckets: [StudyTimeAnalyticsBucket], bounds: DateInterval, calendar: Calendar
    ) -> Bool {
        guard buckets.count == 7 else { return false }
        var cursor = bounds.start
        for bucket in buckets {
            guard bucket.startsAt == cursor,
                  bucket.endsAt == calendar.date(byAdding: .day, value: 1, to: cursor)
            else { return false }
            cursor = bucket.endsAt
        }
        return cursor == bounds.end
    }
}
