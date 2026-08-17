import Foundation

struct StudyTimeSnapshot: Codable, Equatable {
    let savedAt: Date
    let analytics: StudyTimeAnalytics?
    let weeklyRecap: WeeklyStudyRecap?
    let weeklyRecapRefreshedAt: Date?

    init(
        savedAt: Date,
        analytics: StudyTimeAnalytics?,
        weeklyRecap: WeeklyStudyRecap?,
        weeklyRecapRefreshedAt: Date? = nil
    ) {
        self.savedAt = savedAt
        self.analytics = analytics
        self.weeklyRecap = weeklyRecap
        self.weeklyRecapRefreshedAt = weeklyRecapRefreshedAt
    }
}

protocol StudyTimeSnapshotCaching: AnyObject {
    func load(userID: Int, timeZone: String) -> StudyTimeSnapshot?
    func save(_ snapshot: StudyTimeSnapshot, userID: Int, timeZone: String)
    func remove(userID: Int)
}

final class UserDefaultsStudyTimeSnapshotCache: StudyTimeSnapshotCaching {
    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let keyPrefix = "study-time-snapshot-v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load(userID: Int, timeZone: String) -> StudyTimeSnapshot? {
        guard let data = defaults.data(forKey: key(userID: userID, timeZone: timeZone)) else {
            return nil
        }
        return try? decoder.decode(StudyTimeSnapshot.self, from: data)
    }

    func save(_ snapshot: StudyTimeSnapshot, userID: Int, timeZone: String) {
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: key(userID: userID, timeZone: timeZone))
    }

    func remove(userID: Int) {
        let prefix = "\(keyPrefix)-\(userID)-"
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private func key(userID: Int, timeZone: String) -> String {
        "\(keyPrefix)-\(userID)-\(timeZone)"
    }
}
