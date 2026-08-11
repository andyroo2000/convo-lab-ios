import Foundation
import SwiftData

@Observable
final class KnownKanjiService {
    private let api: APIClient
    private let context: ModelContext
    @ObservationIgnored private var activeUserID: Int?
    private var snapshot: KnownKanjiSnapshot?

    private(set) var isWorking = false
    private(set) var errorMessage: String?

    var knownKanji: Set<Character> {
        Set(snapshot?.kanji.compactMap(\.singleCharacter) ?? [])
    }

    var manualKnownKanji: Set<Character> {
        Set(snapshot?.manualKanji.compactMap(\.singleCharacter) ?? [])
    }

    var version: Int {
        snapshot?.version ?? -1
    }

    var wanikaniConnected: Bool {
        snapshot?.wanikani.connected ?? false
    }

    var wanikaniLastSyncedAt: Date? {
        snapshot?.wanikani.lastSyncedAt
    }

    init(api: APIClient, context: ModelContext) {
        self.api = api
        self.context = context
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        activeUserID = userID
        snapshot = loadSnapshot(userID: userID)
        isWorking = false
        errorMessage = nil
    }

    func deactivate() {
        activeUserID = nil
        snapshot = nil
        isWorking = false
        errorMessage = nil
    }

    func stageLocalDataDeletion(userID: Int) throws {
        let records = try context.fetch(
            FetchDescriptor<LocalKnownKanjiSnapshot>(
                predicate: #Predicate { $0.userID == userID }
            )
        )
        records.forEach(context.delete)
    }

    func refresh() async throws {
        guard let userID = activeUserID else { return }
        try await refresh(userID: userID)
    }

    func connect(apiToken: String) async {
        guard let userID = beginOperation() else { return }
        defer { finishOperation(for: userID) }

        do {
            let connectedSnapshot: KnownKanjiSnapshot = try await api.request(
                "/api/study/wanikani",
                method: "PUT",
                body: ConnectWaniKaniRequest(apiToken: apiToken)
            )
            try apply(connectedSnapshot, userID: userID)
            try await synchronize(userID: userID)
        } catch {
            report(error, for: userID)
        }
    }

    func synchronize() async {
        guard let userID = beginOperation() else { return }
        defer { finishOperation(for: userID) }

        do {
            try await synchronize(userID: userID)
        } catch {
            report(error, for: userID)
        }
    }

    func disconnect() async {
        guard let userID = beginOperation() else { return }
        defer { finishOperation(for: userID) }

        do {
            try await api.request(
                "/api/study/wanikani",
                method: "DELETE"
            )
            guard activeUserID == userID else { return }
            try await refresh(userID: userID)
        } catch {
            report(error, for: userID)
        }
    }

    private func beginOperation() -> Int? {
        guard let activeUserID, !isWorking else { return nil }
        isWorking = true
        errorMessage = nil
        return activeUserID
    }

    private func finishOperation(for userID: Int) {
        guard activeUserID == userID else { return }
        isWorking = false
    }

    private func report(_ error: any Error, for userID: Int) {
        guard activeUserID == userID else { return }
        errorMessage = error.localizedDescription
    }

    private func synchronize(userID: Int) async throws {
        guard activeUserID == userID else { return }
        let _: WaniKaniSyncResult = try await api.request(
            "/api/study/wanikani/sync",
            method: "POST"
        )
        guard activeUserID == userID else { return }
        try await refresh(userID: userID)
    }

    private func refresh(userID: Int) async throws {
        guard activeUserID == userID else { return }
        let refreshedSnapshot: KnownKanjiSnapshot = try await api.request(
            "/api/study/known-kanji"
        )
        try apply(refreshedSnapshot, userID: userID)
    }

    private func apply(_ newSnapshot: KnownKanjiSnapshot, userID: Int) throws {
        guard activeUserID == userID else { return }
        guard newSnapshot.version >= version else { return }
        let payload = try StorageCodec.encoder.encode(newSnapshot)
        var descriptor = FetchDescriptor<LocalKnownKanjiSnapshot>(
            predicate: #Predicate { $0.userID == userID }
        )
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.payload = payload
            record.updatedAt = .now
        } else {
            context.insert(LocalKnownKanjiSnapshot(userID: userID, payload: payload))
        }
        try context.save()
        snapshot = newSnapshot
    }

    private func loadSnapshot(userID: Int) -> KnownKanjiSnapshot? {
        var descriptor = FetchDescriptor<LocalKnownKanjiSnapshot>(
            predicate: #Predicate { $0.userID == userID }
        )
        descriptor.fetchLimit = 1
        guard
            let record = try? context.fetch(descriptor).first,
            let snapshot = try? StorageCodec.decoder.decode(
                KnownKanjiSnapshot.self,
                from: record.payload
            )
        else {
            return nil
        }
        return snapshot
    }
}

private extension String {
    var singleCharacter: Character? {
        count == 1 ? first : nil
    }
}
