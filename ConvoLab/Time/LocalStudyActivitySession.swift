import Foundation
import SwiftData

@Model
final class LocalStudyActivitySession {
    var clientSessionID: String
    var userID: Int
    var serverID: String?
    var category: String
    var activity: String
    var source: String
    var name: String?
    var startedAt: Date
    var endedAt: Date?
    var durationMs: Int
    var audioPlaybackMs: Int?
    var cardsCreated: Int?
    var syncPending: Bool

    init(active: StudyTimeStore.ActiveSession, userID: Int) {
        clientSessionID = active.clientSessionID
        self.userID = userID
        category = active.category.rawValue
        activity = active.activity.rawValue
        source = active.source.rawValue
        name = active.name
        startedAt = active.startedAt
        durationMs = 0
        cardsCreated = active.cardsCreated
        syncPending = false
    }

    init(session: StudyActivitySession, userID: Int) {
        clientSessionID = session.clientSessionId
        self.userID = userID
        serverID = session.id
        category = session.category.rawValue
        activity = session.activity.rawValue
        source = session.source.rawValue
        name = session.name
        startedAt = session.startedAt
        endedAt = session.endedAt
        durationMs = session.durationMs
        audioPlaybackMs = session.audioPlaybackMs
        cardsCreated = session.cardsCreated
        syncPending = false
    }

    var session: StudyActivitySession? {
        guard let endedAt,
              let category = StudyActivityCategory(rawValue: category),
              let activity = StudyActivityKind(rawValue: activity),
              let source = StudyActivitySource(rawValue: source)
        else {
            return nil
        }
        return StudyActivitySession(
            id: serverID,
            clientSessionId: clientSessionID,
            category: category,
            activity: activity,
            source: source,
            name: name,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMs: durationMs,
            audioPlaybackMs: audioPlaybackMs,
            cardsCreated: cardsCreated
        )
    }

    var activeSession: StudyTimeStore.ActiveSession? {
        guard endedAt == nil,
              let category = StudyActivityCategory(rawValue: category),
              let activity = StudyActivityKind(rawValue: activity),
              let source = StudyActivitySource(rawValue: source)
        else {
            return nil
        }
        return StudyTimeStore.ActiveSession(
            clientSessionID: clientSessionID,
            category: category,
            activity: activity,
            source: source,
            name: name,
            startedAt: startedAt,
            cardsCreated: cardsCreated ?? 0
        )
    }

    func apply(_ session: StudyActivitySession) {
        serverID = session.id
        category = session.category.rawValue
        activity = session.activity.rawValue
        source = session.source.rawValue
        name = session.name
        startedAt = session.startedAt
        endedAt = session.endedAt
        durationMs = session.durationMs
        audioPlaybackMs = session.audioPlaybackMs
        cardsCreated = session.cardsCreated
        syncPending = false
    }
}

enum StudyTimePersistence {
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([LocalStudyActivitySession.self])
        let configuration = ModelConfiguration(
            "StudyTime",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
