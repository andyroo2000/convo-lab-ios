import Foundation
import SwiftData

@Observable
final class KnownKanjiService {
    private struct Operation: Equatable {
        let userID: Int
        let generation: Int
    }

    private let api: APIClient
    private let context: ModelContext
    @ObservationIgnored private var activeUserID: Int?
    @ObservationIgnored private var activationGeneration = 0
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

    var wanikaniReviewCount: Int? {
        snapshot?.wanikani.reviewCount
    }

    var wanikaniReviewCountUpdatedAt: Date? {
        snapshot?.wanikani.reviewCountUpdatedAt
    }

    init(api: APIClient, context: ModelContext) {
        self.api = api
        self.context = context
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        activationGeneration += 1
        activeUserID = userID
        snapshot = loadSnapshot(userID: userID)
        isWorking = false
        errorMessage = nil
    }

    func deactivate() {
        activationGeneration += 1
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
        guard let operation = activeOperation() else { return }
        try await refresh(operation: operation)
    }

    func connect(apiToken: String) async {
        guard let operation = beginOperation() else { return }
        defer { finishOperation(operation) }

        do {
            let connectedSnapshot: KnownKanjiSnapshot = try await api.request(
                "/api/study/wanikani",
                method: "PUT",
                body: ConnectWaniKaniRequest(apiToken: apiToken)
            )
            try apply(connectedSnapshot, operation: operation)
            guard isCurrent(operation) else { return }
            try await synchronize(operation: operation)
        } catch {
            report(error, operation: operation)
        }
    }

    func synchronize() async {
        guard let operation = beginOperation() else { return }
        defer { finishOperation(operation) }

        do {
            try await synchronize(operation: operation)
        } catch {
            report(error, operation: operation)
        }
    }

    func disconnect() async {
        guard let operation = beginOperation() else { return }
        defer { finishOperation(operation) }

        do {
            try await api.request(
                "/api/study/wanikani",
                method: "DELETE"
            )
            guard isCurrent(operation) else { return }
            try await refresh(operation: operation)
        } catch {
            report(error, operation: operation)
        }
    }

    private func activeOperation() -> Operation? {
        guard let activeUserID else { return nil }
        return Operation(userID: activeUserID, generation: activationGeneration)
    }

    private func beginOperation() -> Operation? {
        guard let operation = activeOperation(), !isWorking else { return nil }
        isWorking = true
        errorMessage = nil
        return operation
    }

    private func finishOperation(_ operation: Operation) {
        guard isCurrent(operation) else { return }
        isWorking = false
    }

    private func report(_ error: any Error, operation: Operation) {
        guard isCurrent(operation) else { return }
        errorMessage = error.localizedDescription
    }

    private func synchronize(operation: Operation) async throws {
        guard isCurrent(operation) else { return }
        let _: WaniKaniSyncResult = try await api.request(
            "/api/study/wanikani/sync",
            method: "POST"
        )
        guard isCurrent(operation) else { return }
        try await refresh(operation: operation)
    }

    private func refresh(operation: Operation) async throws {
        guard isCurrent(operation) else { return }
        let refreshedSnapshot: KnownKanjiSnapshot = try await api.request(
            "/api/study/known-kanji"
        )
        try apply(refreshedSnapshot, operation: operation)
    }

    private func apply(
        _ newSnapshot: KnownKanjiSnapshot,
        operation: Operation
    ) throws {
        guard isCurrent(operation), newSnapshot.version >= version else { return }
        let userID = operation.userID
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

    private func isCurrent(_ operation: Operation) -> Bool {
        activeUserID == operation.userID
            && activationGeneration == operation.generation
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
