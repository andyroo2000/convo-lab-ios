import Foundation

struct StudyTimePeriodSnapshot: Codable, Equatable {
    let value: StudyTimeAnalytics
    let receivedAt: Date
}

struct StudyTimePeriodHistory: Codable, Equatable {
    static let limit = 12
    static let maximumAge: TimeInterval = 7 * 86_400

    let version: Int
    let userID: Int
    let timezone: String
    let weekStartsOn: Int
    let snapshots: [StudyTimePeriodSnapshot]

    init(userID: Int, context: StudyTimeAnalyticsCalendar, snapshots: [StudyTimePeriodSnapshot]) {
        version = 1
        self.userID = userID
        timezone = context.timeZone.identifier
        weekStartsOn = context.weekStartsOn
        self.snapshots = Array(snapshots.suffix(Self.limit))
    }

    func restored(userID: Int, context: StudyTimeAnalyticsCalendar, now: Date) -> [StudyTimePeriodSnapshot] {
        guard version == 1, self.userID == userID,
              timezone == context.timeZone.identifier, weekStartsOn == context.weekStartsOn
        else { return [] }
        return snapshots.suffix(Self.limit).filter {
            let age = now.timeIntervalSince($0.receivedAt)
            return $0.value.timezone == timezone && age >= 0 && age < Self.maximumAge
        }
    }
}

enum StudyTimePeriodFreshness {
    static func isFresh(
        _ entry: StudyTimePeriodCache.Entry, generation: Int,
        now: Date, context: StudyTimeAnalyticsCalendar
    ) -> Bool {
        guard entry.generation == generation else { return false }
        let age = now.timeIntervalSince(entry.receivedAt)
        guard age >= 0 else { return false }
        return entry.value.ranges.allSatisfy { range in
            let open = range.key == .all || range.endsAt > entry.value.generatedAt
            if open && !context.calendar.isDate(entry.receivedAt, inSameDayAs: now) { return false }
            return age < (open ? 2 * 60 : 15 * 60)
        }
    }
}
