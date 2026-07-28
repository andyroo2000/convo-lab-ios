import Foundation
import SwiftData

@Observable
final class StudyTimeStore {
    private static let automaticRecoveryLimit: TimeInterval = 5 * 60

    struct ActiveSession: Equatable {
        let clientSessionID: String
        let category: StudyActivityCategory
        let activity: StudyActivityKind
        let source: StudyActivitySource
        let name: String?
        let startedAt: Date
        var cardsCreated: Int
    }

    private let api: APIClient
    private let context: ModelContext
    private(set) var sessions: [StudyActivitySession] = []
    private(set) var active: ActiveSession?
    private(set) var syncErrorMessage: String?
    private var activeUserID: Int?
    private var synchronizationInFlight = false
    private var pendingPushTask: Task<Void, Never>?

    init(api: APIClient, context: ModelContext) {
        self.api = api
        self.context = context
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        activeUserID = userID
        loadLocalSessions(recoverAbandonedAutomatic: true)
    }

    func deactivate(at date: Date = .now) async {
        if let active {
            finish(active, at: date, enqueueSync: false)
        }
        await pushPending()
        activeUserID = nil
        sessions = []
        active = nil
        syncErrorMessage = nil
    }

    func start(
        activity: StudyActivityKind,
        source: StudyActivitySource,
        name: String? = nil,
        at date: Date = .now
    ) {
        guard let userID = activeUserID else { return }
        if active?.activity == activity, active?.source == source, active?.name == name {
            return
        }
        if active?.source == .manual, source == .automatic {
            return
        }
        stop(at: date)
        let session = ActiveSession(
            clientSessionID: UUID().uuidString.lowercased(),
            category: activity.category,
            activity: activity,
            source: source,
            name: name,
            startedAt: date,
            cardsCreated: 0
        )
        active = session
        context.insert(LocalStudyActivitySession(active: session, userID: userID))
        try? context.save()
    }

    func stop(
        activity expectedActivity: StudyActivityKind? = nil,
        source expectedSource: StudyActivitySource? = nil,
        at date: Date = .now
    ) {
        guard let current = active,
              expectedActivity == nil || current.activity == expectedActivity,
              expectedSource == nil || current.source == expectedSource
        else {
            return
        }
        finish(current, at: date)
    }

    func addCreatedCards(_ count: Int = 1) {
        guard var current = active, current.activity == .cardCreation else { return }
        current.cardsCreated += count
        active = current
        guard let record = record(clientSessionID: current.clientSessionID) else { return }
        record.cardsCreated = current.cardsCreated
        try? context.save()
    }

    func recordCompleted(
        activity: StudyActivityKind,
        source: StudyActivitySource,
        name: String?,
        startedAt: Date,
        duration: TimeInterval,
        addToCalendar: Bool = false
    ) async throws -> String? {
        guard let userID = activeUserID else { return nil }
        let boundedDuration = max(0, min(duration, 86_400))
        let endedAt = startedAt.addingTimeInterval(boundedDuration)
        let session = ActiveSession(
            clientSessionID: UUID().uuidString.lowercased(),
            category: activity.category,
            activity: activity,
            source: source,
            name: name,
            startedAt: startedAt,
            cardsCreated: 0
        )
        let record = LocalStudyActivitySession(active: session, userID: userID)
        context.insert(record)
        complete(record, from: session, at: endedAt)
        try context.save()
        loadLocalSessions()
        await pushPending()
        guard addToCalendar else { return nil }
        do {
            try await StudyCalendarService.addEvent(
                title: name ?? activity.title,
                start: startedAt,
                end: endedAt
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func synchronize() async {
        guard let userID = activeUserID, !synchronizationInFlight else { return }
        synchronizationInFlight = true
        defer { synchronizationInFlight = false }
        await pushPending()
        let from = Calendar.current.date(byAdding: .day, value: -93, to: .now) ?? .distantPast
        do {
            let remote = try await api.request(
                "/api/study/activity-sessions",
                query: [
                    URLQueryItem(name: "from", value: from.ISO8601Format()),
                    URLQueryItem(name: "to", value: Date.now.addingTimeInterval(86_400).ISO8601Format()),
                ],
                response: [StudyActivitySession].self
            )
            let existing = try context.fetch(
                FetchDescriptor<LocalStudyActivitySession>(
                    predicate: #Predicate { $0.userID == userID }
                )
            )
            let recordsByID = existing.reduce(into: [String: LocalStudyActivitySession]()) {
                records, record in
                if records[record.clientSessionID] == nil {
                    records[record.clientSessionID] = record
                }
            }
            for session in remote {
                if let record = recordsByID[session.clientSessionId] {
                    record.apply(session)
                } else {
                    context.insert(LocalStudyActivitySession(session: session, userID: userID))
                }
            }
            try context.save()
            syncErrorMessage = nil
            loadLocalSessions()
        } catch {
            syncErrorMessage = error.localizedDescription
        }
    }

    func deleteLocalData(userID: Int) throws {
        try context.delete(
            model: LocalStudyActivitySession.self,
            where: #Predicate { $0.userID == userID }
        )
        if activeUserID == userID {
            sessions = []
            active = nil
        }
        try context.save()
    }

    private func finish(
        _ current: ActiveSession,
        at date: Date,
        enqueueSync: Bool = true
    ) {
        guard let record = record(clientSessionID: current.clientSessionID) else {
            active = nil
            return
        }
        complete(record, from: current, at: date)
        active = nil
        try? context.save()
        loadLocalSessions()
        if enqueueSync {
            Task { await pushPending() }
        }
    }

    private func complete(
        _ record: LocalStudyActivitySession,
        from active: ActiveSession,
        at date: Date
    ) {
        let durationMs = min(
            86_400_000,
            max(0, Int(date.timeIntervalSince(active.startedAt) * 1_000))
        )
        record.endedAt = date
        record.durationMs = durationMs
        record.audioPlaybackMs = active.activity == .dailyAudio ? durationMs : nil
        record.cardsCreated = active.cardsCreated > 0 ? active.cardsCreated : nil
        record.syncPending = true
    }

    private func pushPending() async {
        if let pendingPushTask {
            await pendingPushTask.value
            return
        }
        guard let userID = activeUserID else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performPushPending(userID: userID)
        }
        pendingPushTask = task
        await task.value
        pendingPushTask = nil
    }

    private func performPushPending(userID: Int) async {
        do {
            let pending = try context.fetch(
                FetchDescriptor<LocalStudyActivitySession>(
                    predicate: #Predicate {
                        $0.userID == userID && $0.syncPending && $0.endedAt != nil
                    }
                )
            )
            guard !pending.isEmpty else { return }
            let payload = pending.compactMap(\.session)
            let saved = try await api.request(
                "/api/study/activity-sessions/batch",
                method: "POST",
                body: StudyActivityBatchRequest(sessions: payload),
                response: [StudyActivitySession].self
            )
            let savedIDs = Set(saved.map(\.clientSessionId))
            pending.filter { savedIDs.contains($0.clientSessionID) }.forEach {
                $0.syncPending = false
            }
            try context.save()
            syncErrorMessage = nil
            loadLocalSessions()
        } catch {
            syncErrorMessage = error.localizedDescription
        }
    }

    private func loadLocalSessions(recoverAbandonedAutomatic: Bool = false) {
        guard let userID = activeUserID else { return }
        let descriptor = FetchDescriptor<LocalStudyActivitySession>(
            predicate: #Predicate { $0.userID == userID },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        guard let records = try? context.fetch(descriptor) else { return }
        sessions = records.compactMap(\.session)
        if let running = records.first(where: { $0.endedAt == nil }) {
            active = running.activeSession
            if recoverAbandonedAutomatic,
               let active,
               active.source == .automatic,
               Date.now.timeIntervalSince(active.startedAt) > Self.automaticRecoveryLimit
            {
                finish(
                    active,
                    at: active.startedAt.addingTimeInterval(Self.automaticRecoveryLimit)
                )
            }
        } else {
            active = nil
        }
    }

    private func record(clientSessionID: String) -> LocalStudyActivitySession? {
        guard let userID = activeUserID else { return nil }
        var descriptor = FetchDescriptor<LocalStudyActivitySession>(
            predicate: #Predicate {
                $0.userID == userID && $0.clientSessionID == clientSessionID
            }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
