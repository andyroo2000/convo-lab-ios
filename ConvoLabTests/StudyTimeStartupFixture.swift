import Foundation
import SwiftData
@testable import ConvoLab

@MainActor
final class StudyTimeStartupFixture {
    let historyCount: Int
    let pendingCount: Int
    let now: Date
    let directory: URL
    let host = "time-startup-\(UUID().uuidString.lowercased()).invalid"
    let suite = "time-startup-\(UUID())"
    let defaults: UserDefaults
    let container: ModelContainer
    let session: URLSession
    let store: StudyTimeStore
    let transport: StudyTimeStartupTransport
    let expected: [StudyActivitySession]
    let analytics: StudyTimeAnalytics

    init(large: Bool, cached: Bool) throws {
        let requestedCount = Int(ProcessInfo.processInfo.environment["TIME_STARTUP_HISTORY_COUNT"] ?? "") ?? 2_631
        historyCount = large ? min(20_000, max(1, requestedCount)) : 120
        pendingCount = large ? 30 : 3
        let periods = StudyTimePeriodFixture(timezone: TimeZone.current.identifier, now: "2026-10-19T16:00:00Z")
        now = periods.now
        expected = Self.sessions(count: historyCount, pending: pendingCount, now: now)
        analytics = Self.analytics(periods: periods, sessions: expected)
        directory = FileManager.default.temporaryDirectory.appending(path: "TimeStartup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema([LocalStudyActivitySession.self])
        let configuration = ModelConfiguration(schema: schema, url: directory.appending(path: "time.store"),
                                               cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [configuration])
        defaults = UserDefaults(suiteName: suite)!
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        transport = StudyTimeStartupTransport(history: try Self.serverHistory(expected, encoder: encoder),
                                             analyticsByScope: try Self.scopedPayloads(analytics, encoder: encoder),
                                             large: large)
        StudyTimeStartupURLProtocol.install(transport, host: host)
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [StudyTimeStartupURLProtocol.self]
        session = URLSession(configuration: network)
        let api = APIClient(baseURL: URL(string: "https://\(host)")!, session: session)
        api.setAccessToken("isolated-startup-fixture")
        let cache = UserDefaultsStudyTimeSnapshotCache(defaults: defaults)
        if cached { Self.seedSnapshot(analytics, cache: cache) }
        let fixedNow = now
        store = StudyTimeStore(api: api, context: container.mainContext, snapshotCache: cache,
                               activityCategoryDefaults: defaults, now: { fixedNow })
        try seedSessions(cached: cached)
    }

    func cleanup() {
        session.invalidateAndCancel()
        StudyTimeStartupURLProtocol.remove(host: host)
        defaults.removePersistentDomain(forName: suite)
        // SwiftData may retain SQLite handles past fixture teardown. Leave this
        // unique temporary store for process-exit cleanup, never unlink it live.
    }

    private func seedSessions(cached: Bool) throws {
        let records = cached ? expected : Array(expected.suffix(pendingCount))
        let pendingIDs = Set(expected.suffix(pendingCount).map(\.clientSessionId))
        for session in records {
            let record = LocalStudyActivitySession(session: session, userID: 42)
            if pendingIDs.contains(session.clientSessionId) {
                record.serverID = nil
                record.syncPending = true
            }
            container.mainContext.insert(record)
        }
        try container.mainContext.save()
    }

    private static func seedSnapshot(_ value: StudyTimeAnalytics, cache: UserDefaultsStudyTimeSnapshotCache) {
        let savedAt = value.generatedAt.addingTimeInterval(-60)
        let previous = StudyTimeAnalytics(generatedAt: savedAt, anchorDate: value.anchorDate,
                                          timezone: value.timezone, ranges: value.ranges)
        cache.save(.init(savedAt: savedAt, analytics: previous, weeklyRecap: nil),
                   userID: 42, timeZone: value.timezone)
    }

    private static func serverHistory(_ sessions: [StudyActivitySession], encoder: JSONEncoder) throws -> Data {
        // The client's write encoder deliberately omits server-owned provenance.
        // History responses must include it, just as the production API does.
        var values = try JSONSerialization.jsonObject(with: encoder.encode(sessions)) as! [[String: Any]]
        for index in sessions.indices { values[index]["origin"] = sessions[index].origin.rawValue }
        return try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    }

    private static func sessions(count: Int, pending: Int, now: Date) -> [StudyActivitySession] {
        let activities: [StudyActivityKind] = [.cardReview, .dailyAudio, .cardCreation, .reading,
                                              .conversation, .wanikaniReview]
        return (0..<(count + pending)).map { index in
            let isPending = index >= count
            let position = isPending ? index - count : index
            let activity = activities[index % activities.count]
            let age = isPending ? Double(position + 1) * 120 : Double(index + 1) * (90 * 86_400 / Double(count))
            // Match the wire encoder precision so cached rows are genuinely unchanged.
            let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 - age - 60).rounded(.down))
            let calendar = !isPending && index.isMultiple(of: 3)
            return .init(id: isPending ? "uploaded-\(position)" : "remote-\(index)",
                         clientSessionId: isPending ? "pending-\(position)" : "history-\(index)",
                         category: activity.offlineFallbackCategory, activity: activity,
                         source: calendar ? .calendar : .manual, origin: calendar ? .googleCalendar : .ios,
                         name: "\(activity.rawValue) 日本語の学習 \(index)", startedAt: start,
                         endedAt: start.addingTimeInterval(60), durationMs: 60_000,
                         audioPlaybackMs: activity == .dailyAudio ? 60_000 : nil,
                         cardsCreated: activity == .cardCreation ? 2 : nil)
        }
    }

    private static func analytics(periods: StudyTimePeriodFixture, sessions: [StudyActivitySession]) -> StudyTimeAnalytics {
        let template = periods.response(anchor: periods.now)
        let ranges = template.ranges.map { range in
            let buckets = range.buckets.map { bucket in
                let totals = sessions.reduce(into: [String: Int]()) { result, session in
                    let overlap = min(session.endedAt, bucket.endsAt).timeIntervalSince(max(session.startedAt, bucket.startsAt))
                    if overlap > 0 { result[session.category.rawValue, default: 0] += Int((overlap * 1_000).rounded()) }
                }
                return StudyTimeAnalyticsBucket(startsAt: bucket.startsAt, endsAt: bucket.endsAt,
                                                 totalMs: totals.values.reduce(0, +), categories: totals)
            }
            let categories = buckets.reduce(into: [String: Int]()) { result, bucket in
                for (key, duration) in bucket.categories { result[key, default: 0] += duration }
            }
            return StudyTimeAnalyticsRange(key: range.key, startsAt: range.startsAt, endsAt: range.endsAt,
                                            totalMs: categories.values.reduce(0, +), categories: categories, buckets: buckets)
        }
        return .init(generatedAt: periods.now, anchorDate: template.anchorDate, timezone: template.timezone, ranges: ranges)
    }

    private static func scopedPayloads(_ value: StudyTimeAnalytics, encoder: JSONEncoder) throws -> [String: Data] {
        var result = ["": try encoder.encode(value)]
        let ranges = value.ranges
        for mask in 1..<(1 << ranges.count) {
            let selected = ranges.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            let key = selected.map { $0.key.rawValue }.sorted().joined(separator: ",")
            result[key] = try encoder.encode(StudyTimeAnalytics(generatedAt: value.generatedAt,
                                                                anchorDate: value.anchorDate,
                                                                timezone: value.timezone, ranges: selected))
        }
        return result
    }
}
