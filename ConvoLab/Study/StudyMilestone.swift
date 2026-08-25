import Foundation

enum StudyMilestoneID: String, nonisolated Codable, CaseIterable, Sendable {
    case burned100
    case burned500
    case burned1000

    var definition: StudyMilestoneDefinition {
        switch self {
        case .burned100:
            StudyMilestoneDefinition(
                id: self,
                threshold: 100,
                badgeText: "100",
                title: "100 items burned",
                detail: "One hundred cards have reached a year of memory stability."
            )
        case .burned500:
            StudyMilestoneDefinition(
                id: self,
                threshold: 500,
                badgeText: "500",
                title: "500 items burned",
                detail: "Five hundred cards have reached a year of memory stability."
            )
        case .burned1000:
            StudyMilestoneDefinition(
                id: self,
                threshold: 1_000,
                badgeText: "1K",
                title: "1,000 items burned",
                detail: "One thousand cards have reached a year of memory stability."
            )
        }
    }
}

struct StudyMilestoneDefinition: Identifiable, Equatable, Sendable {
    let id: StudyMilestoneID
    let threshold: Int
    let badgeText: String
    let title: String
    let detail: String
}

struct StudyMilestoneAward: nonisolated Codable, Identifiable, Equatable, Sendable {
    let id: StudyMilestoneID
    let earnedAt: Date
    let presentedAt: Date?

    var definition: StudyMilestoneDefinition { id.definition }
}

struct StudyMilestoneSnapshot: nonisolated Codable, Equatable, Sendable {
    let milestones: [StudyMilestoneAward]
    let pendingMilestones: [StudyMilestoneAward]
}

private struct PresentStudyMilestonesRequest: nonisolated Encodable, Sendable {
    let milestoneIds: [StudyMilestoneID]
}

struct StudyMilestoneCompletion: Identifiable, Equatable, Sendable {
    let id: UUID
    let records: [StudySessionReviewRecord]
    let newAwards: [StudyMilestoneAward]
    let celebrationPresented: Bool
}

@MainActor
@Observable
final class StudyMilestoneStore {
    private struct ReviewSession: Codable, Equatable {
        let id: UUID
        let startedAt: Date
        var records: [StudySessionReviewRecord]
        var newAwardIDs: [StudyMilestoneID]
        var isReadyForPresentation: Bool
        var celebrationPresented: Bool
    }

    private struct PersistedState: Codable, Equatable {
        var earnedAwards: [StudyMilestoneAward] = []
        var activeSession: ReviewSession?
    }

    private let api: APIClient?
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let keyPrefix = "study-milestones-v1"
    private var activeUserID: Int?
    private var state = PersistedState()

    init(api: APIClient? = nil, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    var earnedAwards: [StudyMilestoneAward] {
        state.earnedAwards.sorted {
            if $0.earnedAt != $1.earnedAt { return $0.earnedAt > $1.earnedAt }
            return $0.definition.threshold > $1.definition.threshold
        }
    }

    var upcomingMilestones: [StudyMilestoneDefinition] {
        let earnedIDs = Set(state.earnedAwards.map(\.id))
        return StudyMilestoneID.allCases
            .filter { !earnedIDs.contains($0) }
            .map(\.definition)
            .sorted { $0.threshold < $1.threshold }
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        activeUserID = userID
        state = load(userID: userID)
    }

    func deactivate() {
        activeUserID = nil
        state = PersistedState()
    }

    func synchronize() async throws -> StudyMilestoneSnapshot {
        guard let api else {
            return StudyMilestoneSnapshot(milestones: earnedAwards, pendingMilestones: [])
        }
        let snapshot: StudyMilestoneSnapshot = try await api.request(
            "/api/study/milestones/evaluate",
            method: "POST"
        )
        applyServerSnapshot(snapshot)
        return snapshot
    }

    func acknowledgePresentation(_ ids: [StudyMilestoneID]) async throws {
        guard !ids.isEmpty, let api else { return }
        try await api.request(
            "/api/study/milestones/present",
            method: "POST",
            body: PresentStudyMilestonesRequest(milestoneIds: ids)
        )
    }

    func applyServerSnapshot(_ snapshot: StudyMilestoneSnapshot) {
        state.earnedAwards = snapshot.milestones
        persist()
    }

    func beginReviewSession(at startedAt: Date = .now) {
        guard activeUserID != nil else { return }

        if state.activeSession?.isReadyForPresentation == true {
            persist()
            return
        }

        state.activeSession = ReviewSession(
            id: UUID(),
            startedAt: startedAt,
            records: [],
            newAwardIDs: [],
            isReadyForPresentation: false,
            celebrationPresented: false
        )
        persist()
    }

    func recordReview(_ record: StudySessionReviewRecord) {
        guard var session = state.activeSession, !session.isReadyForPresentation else { return }
        session.records.removeAll { $0.id == record.id }
        session.records.append(record)
        state.activeSession = session
        // The server owns award qualification, but this local record set is what lets a
        // force-quit restore the matching wrap-up after the pending award is recovered.
        persist()
    }

    func undoReview(eventID: String) {
        guard var session = state.activeSession, !session.isReadyForPresentation else { return }
        session.records.removeAll { $0.id == eventID }
        state.activeSession = session
        persist()
    }

    func prepareCurrentSessionCompletion(
        newAwards: [StudyMilestoneAward] = []
    ) -> StudyMilestoneCompletion? {
        prepareCompletion(newAwards: newAwards, requireNewAward: false)
    }

    func prepareInterruptedCompletion(
        newAwards: [StudyMilestoneAward] = []
    ) -> StudyMilestoneCompletion? {
        prepareCompletion(newAwards: newAwards, requireNewAward: true)
    }

    func markCelebrationPresented(sessionID: UUID) {
        guard var session = state.activeSession, session.id == sessionID else { return }
        session.celebrationPresented = true
        state.activeSession = session
        persist()
    }

    func consumeCompletion(sessionID: UUID) {
        guard state.activeSession?.id == sessionID else { return }
        state.activeSession = nil
        persist()
    }

    func cancelCurrentSession() {
        guard state.activeSession?.isReadyForPresentation != true else { return }
        state.activeSession = nil
        persist()
    }

    func deleteLocalData(userID: Int) {
        defaults.removeObject(forKey: key(userID: userID))
        if activeUserID == userID {
            state = PersistedState()
        }
    }

    private func prepareCompletion(
        newAwards: [StudyMilestoneAward],
        requireNewAward: Bool
    ) -> StudyMilestoneCompletion? {
        guard var session = state.activeSession, !session.records.isEmpty else { return nil }

        if !session.isReadyForPresentation {
            guard !requireNewAward || !newAwards.isEmpty else { return nil }
            session.isReadyForPresentation = true
            session.newAwardIDs = newAwards.map(\.id)
        } else if session.newAwardIDs.isEmpty, !newAwards.isEmpty {
            // A completion prepared offline can still pick up the award after the
            // authoritative review state reaches the server. Once committed, keep it.
            session.newAwardIDs = newAwards.map(\.id)
        }

        mergeAwards(newAwards)
        state.activeSession = session
        persist()

        return completion(from: session)
    }

    private func completion(from session: ReviewSession) -> StudyMilestoneCompletion {
        let awardsByID = Dictionary(uniqueKeysWithValues: state.earnedAwards.map { ($0.id, $0) })
        return StudyMilestoneCompletion(
            id: session.id,
            records: session.records,
            newAwards: session.newAwardIDs.compactMap { awardsByID[$0] },
            celebrationPresented: session.celebrationPresented
        )
    }

    private func mergeAwards(_ awards: [StudyMilestoneAward]) {
        var awardsByID = Dictionary(uniqueKeysWithValues: state.earnedAwards.map { ($0.id, $0) })
        for award in awards {
            awardsByID[award.id] = award
        }
        state.earnedAwards = Array(awardsByID.values)
    }

    private func load(userID: Int) -> PersistedState {
        guard let data = defaults.data(forKey: key(userID: userID)) else {
            return PersistedState()
        }
        return (try? decoder.decode(PersistedState.self, from: data)) ?? PersistedState()
    }

    private func persist() {
        guard let activeUserID, let data = try? encoder.encode(state) else { return }
        defaults.set(data, forKey: key(userID: activeUserID))
    }

    private func key(userID: Int) -> String {
        "\(keyPrefix)-\(userID)"
    }
}
