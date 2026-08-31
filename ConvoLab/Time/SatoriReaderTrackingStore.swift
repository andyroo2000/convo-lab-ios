import Foundation

nonisolated struct SatoriReaderTrackedSession: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let userID: Int
    let startedAt: Date
    let endedAt: Date

    var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }
}

nonisolated struct SatoriReaderTrackingSnapshot: Equatable, Sendable {
    nonisolated enum DetectionStatus: Equatable, Sendable {
        case notDetected
        case partiallyDetected
        case detected
    }

    nonisolated enum VerificationStatus: Equatable, Sendable {
        case notStarted
        case waiting
        case partiallyDetected
        case succeeded
    }

    let lastStartedAt: Date?
    let lastStoppedAt: Date?
    let verificationStartedAt: Date?

    var detectionStatus: DetectionStatus {
        switch (lastStartedAt, lastStoppedAt) {
        case (.some, .some): .detected
        case (.some, .none), (.none, .some): .partiallyDetected
        case (.none, .none): .notDetected
        }
    }

    var verificationStatus: VerificationStatus {
        guard let verificationStartedAt else { return .notStarted }
        let detectedStart = lastStartedAt.map { $0 >= verificationStartedAt } ?? false
        let detectedStop = lastStoppedAt.map { $0 >= verificationStartedAt } ?? false
        return switch (detectedStart, detectedStop) {
        case (true, true): VerificationStatus.succeeded
        case (true, false), (false, true): VerificationStatus.partiallyDetected
        case (false, false): VerificationStatus.waiting
        }
    }
}

/// A durable bridge between App Intents and the authenticated study-time store.
/// App Intents can run while ConvoLab is suspended, so they only append receipts
/// here. The app imports completed intervals through its normal sync outbox later.
nonisolated final class SatoriReaderTrackingStore: @unchecked Sendable {
    static let shared = SatoriReaderTrackingStore()

    private nonisolated struct ActiveSession: Codable, Equatable {
        let userID: Int?
        let startedAt: Date
    }

    private nonisolated struct State: Codable, Equatable {
        var activeUserID: Int?
        var activeSession: ActiveSession?
        var pendingSessions: [SatoriReaderTrackedSession] = []
        var lastStartedAt: Date?
        var lastStoppedAt: Date?
        var verificationStartedAt: Date?
    }

    private static let persistenceKey = "satoriReaderTracking.v1"
    private static let maximumSessionDuration: TimeInterval = 24 * 60 * 60
    private static let persistenceLock = NSLock()

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func setActiveUserID(_ userID: Int?) {
        updateState { state in
            if state.activeUserID != userID {
                state.activeSession = nil
            }
            state.activeUserID = userID
        }
    }

    func recordStart(at date: Date = .now) {
        updateState { state in
            state.lastStartedAt = date
            // A new open event replaces an abandoned one whose close automation
            // never arrived, preventing a later close from logging an all-day session.
            state.activeSession = ActiveSession(
                userID: state.activeUserID,
                startedAt: date
            )
        }
    }

    func recordStop(at date: Date = .now) {
        updateState { state in
            state.lastStoppedAt = date
            defer { state.activeSession = nil }
            guard let activeSession = state.activeSession,
                  let userID = activeSession.userID,
                  date > activeSession.startedAt
            else { return }
            let endedAt = min(
                date,
                activeSession.startedAt.addingTimeInterval(Self.maximumSessionDuration)
            )
            state.pendingSessions.append(
                SatoriReaderTrackedSession(
                    id: UUID().uuidString.lowercased(),
                    userID: userID,
                    startedAt: activeSession.startedAt,
                    endedAt: endedAt
                )
            )
        }
    }

    func beginVerification(at date: Date = .now) {
        updateState { state in
            state.verificationStartedAt = date
        }
    }

    func snapshot() -> SatoriReaderTrackingSnapshot {
        withState { state in
            SatoriReaderTrackingSnapshot(
                lastStartedAt: state.lastStartedAt,
                lastStoppedAt: state.lastStoppedAt,
                verificationStartedAt: state.verificationStartedAt
            )
        }
    }

    func pendingSessions(userID: Int) -> [SatoriReaderTrackedSession] {
        withState { state in
            state.pendingSessions.filter { $0.userID == userID }
        }
    }

    func acknowledge(sessionID: String, userID: Int) {
        updateState { state in
            state.pendingSessions.removeAll {
                $0.id == sessionID && $0.userID == userID
            }
        }
    }

    func removeAccountData(userID: Int) {
        updateState { state in
            state.pendingSessions.removeAll { $0.userID == userID }
            if state.activeSession?.userID == userID {
                state.activeSession = nil
            }
            if state.activeUserID == userID {
                state.activeUserID = nil
            }
        }
    }

    private func withState<T>(_ body: (State) -> T) -> T {
        Self.persistenceLock.lock()
        defer { Self.persistenceLock.unlock() }
        return body(loadState())
    }

    private func updateState(_ body: (inout State) -> Void) {
        Self.persistenceLock.lock()
        defer { Self.persistenceLock.unlock() }
        var state = loadState()
        body(&state)
        if let data = try? encoder.encode(state) {
            defaults.set(data, forKey: Self.persistenceKey)
        }
    }

    private func loadState() -> State {
        guard let data = defaults.data(forKey: Self.persistenceKey),
              let state = try? decoder.decode(State.self, from: data)
        else { return State() }
        return state
    }
}
