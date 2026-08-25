import Foundation

enum StudyMilestoneID: String, Codable, CaseIterable, Sendable {
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

struct StudyMilestoneAward: Identifiable, Codable, Equatable, Sendable {
    let id: StudyMilestoneID
    let earnedAt: Date

    var definition: StudyMilestoneDefinition { id.definition }
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
        let initialBurnedCount: Int
        var records: [StudySessionReviewRecord]
        var newAwardIDs: [StudyMilestoneID]
        var isReadyForPresentation: Bool
        var celebrationPresented: Bool
    }

    private struct PersistedState: Codable, Equatable {
        var earnedAwards: [StudyMilestoneAward] = []
        var activeSession: ReviewSession?
        var hasSeededBurnedMilestones = false
        var lastKnownBurnedCount = 0
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let keyPrefix = "study-milestones-v1"
    private var activeUserID: Int?
    private var state = PersistedState()

    init(defaults: UserDefaults = .standard) {
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

    var lastKnownBurnedCount: Int { state.lastKnownBurnedCount }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        activeUserID = userID
        state = load(userID: userID)
    }

    func deactivate() {
        activeUserID = nil
        state = PersistedState()
    }

    func beginReviewSession(
        burnedCount: Int,
        at startedAt: Date = .now
    ) {
        guard activeUserID != nil else { return }
        let burnedCount = max(0, burnedCount)
        seedExistingMilestonesIfNeeded(burnedCount: burnedCount, at: startedAt)
        state.lastKnownBurnedCount = burnedCount

        if state.activeSession?.isReadyForPresentation == true {
            persist()
            return
        }

        state.activeSession = ReviewSession(
            id: UUID(),
            startedAt: startedAt,
            initialBurnedCount: burnedCount,
            records: [],
            newAwardIDs: [],
            isReadyForPresentation: false,
            celebrationPresented: false
        )
        persist()
    }

    func recordReview(_ record: StudySessionReviewRecord) {
        guard var session = state.activeSession, !session.isReadyForPresentation else { return }
        let wasQualifyingForNewAward = !newMilestoneIDs(
            forBurnedCount: state.lastKnownBurnedCount
        ).isEmpty
        session.records.removeAll { $0.id == record.id }
        session.records.append(record)
        state.activeSession = session
        updateLastKnownBurnedCount(for: session)
        if wasQualifyingForNewAward
            || !newMilestoneIDs(forBurnedCount: state.lastKnownBurnedCount).isEmpty
        {
            // Ordinary interrupted sessions are intentionally discarded, so avoid encoding
            // their growing card history on every grade. Persist as soon as an award is at
            // stake so a force-quit can still restore the complete celebration and wrap-up.
            persist()
        }
    }

    func undoReview(eventID: String) {
        guard var session = state.activeSession, !session.isReadyForPresentation else { return }
        let wasQualifyingForNewAward = !newMilestoneIDs(
            forBurnedCount: state.lastKnownBurnedCount
        ).isEmpty
        session.records.removeAll { $0.id == eventID }
        state.activeSession = session
        updateLastKnownBurnedCount(for: session)
        if wasQualifyingForNewAward
            || !newMilestoneIDs(forBurnedCount: state.lastKnownBurnedCount).isEmpty
        {
            persist()
        }
    }

    func prepareCurrentSessionCompletion(at earnedAt: Date = .now) -> StudyMilestoneCompletion? {
        prepareCompletion(requireNewAward: false, earnedAt: earnedAt)
    }

    func prepareInterruptedCompletion(at earnedAt: Date = .now) -> StudyMilestoneCompletion? {
        prepareCompletion(requireNewAward: true, earnedAt: earnedAt)
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
        requireNewAward: Bool,
        earnedAt: Date
    ) -> StudyMilestoneCompletion? {
        guard var session = state.activeSession, !session.records.isEmpty else { return nil }

        if !session.isReadyForPresentation {
            let newIDs = newMilestoneIDs(for: session)
            guard !requireNewAward || !newIDs.isEmpty else { return nil }

            for id in newIDs {
                state.earnedAwards.append(StudyMilestoneAward(id: id, earnedAt: earnedAt))
            }
            session.newAwardIDs = newIDs
            session.isReadyForPresentation = true
            state.activeSession = session
            updateLastKnownBurnedCount(for: session)
            persist()
        }

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

    private func newMilestoneIDs(for session: ReviewSession) -> [StudyMilestoneID] {
        let summary = StudySessionWrapUpSummary.build(from: session.records)
        let burnedCount = max(0, session.initialBurnedCount + summary.burnedCountChange)
        return newMilestoneIDs(forBurnedCount: burnedCount)
    }

    private func newMilestoneIDs(forBurnedCount burnedCount: Int) -> [StudyMilestoneID] {
        let earnedIDs = Set(state.earnedAwards.map(\.id))
        return StudyMilestoneID.allCases
            .filter { !earnedIDs.contains($0) && burnedCount >= $0.definition.threshold }
            .sorted { $0.definition.threshold < $1.definition.threshold }
    }

    private func seedExistingMilestonesIfNeeded(burnedCount: Int, at date: Date) {
        guard !state.hasSeededBurnedMilestones else { return }
        let existingIDs = Set(state.earnedAwards.map(\.id))
        for id in StudyMilestoneID.allCases
        where burnedCount >= id.definition.threshold && !existingIDs.contains(id) {
            state.earnedAwards.append(StudyMilestoneAward(id: id, earnedAt: date))
        }
        state.hasSeededBurnedMilestones = true
    }

    private func updateLastKnownBurnedCount(for session: ReviewSession) {
        let summary = StudySessionWrapUpSummary.build(from: session.records)
        state.lastKnownBurnedCount = max(
            0,
            session.initialBurnedCount + summary.burnedCountChange
        )
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
