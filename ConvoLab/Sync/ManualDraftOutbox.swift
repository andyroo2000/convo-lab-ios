import Foundation
import SwiftData

enum ManualDraftCommitRecoveryState: Equatable {
    case none
    case rejected
    case outcomeUnknown
    case cleanupPending
}

struct PendingManualDraftCommitError: LocalizedError {
    var errorDescription: String? {
        "This draft may already have created a card. Retry Create Card or sync before deleting it."
    }
}

@Observable
final class ManualDraftOutbox {
    private let api: APIClient
    private let context: ModelContext
    @ObservationIgnored private var activeUserID: Int?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var createTasks: [
        String: Task<StudyManualCardDraft, Error>
    ] = [:]
    @ObservationIgnored private var commitTasks: [String: Task<Void, Error>] = [:]
    @ObservationIgnored private var fetchTasks: [
        String: Task<StudyManualCardDraft, Error>
    ] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Error>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var draftRevisions: [String: Int] = [:]

    private(set) var drafts: [StudyManualCardDraft] = []

    init(api: APIClient, context: ModelContext) {
        self.api = api
        self.context = context
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        deactivate()
        activeUserID = userID
    }

    func deactivate() {
        generation += 1
        createTasks.values.forEach { $0.cancel() }
        commitTasks.values.forEach { $0.cancel() }
        fetchTasks.values.forEach { $0.cancel() }
        refreshTask?.cancel()
        createTasks.removeAll()
        commitTasks.removeAll()
        fetchTasks.removeAll()
        refreshTask = nil
        activeUserID = nil
        drafts = []
        revision += 1
        draftRevisions = [:]
    }

    func refresh() async throws {
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let userID = activeUserID else { return }
        let operationGeneration = generation
        let startingRevision = revision
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let fetched = try await fetchAll(
                userID: userID,
                generation: operationGeneration
            )
            try ensureActive(userID: userID, generation: operationGeneration)
            guard revision == startingRevision else { return }
            applyFetchedDrafts(fetched)
        }
        refreshTask = task
        defer {
            if generation == operationGeneration {
                refreshTask = nil
            }
        }
        try await task.value
    }

    @discardableResult
    func fetch(id: String) async throws -> StudyManualCardDraft {
        if let task = fetchTasks[id] {
            return try await task.value
        }
        guard let userID = activeUserID else { throw CancellationError() }
        let operationGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            return try await performFetch(
                id: id,
                userID: userID,
                generation: operationGeneration
            )
        }
        fetchTasks[id] = task
        defer {
            if generation == operationGeneration {
                fetchTasks[id] = nil
            }
        }
        return try await task.value
    }

    private func performFetch(
        id: String,
        userID: Int,
        generation operationGeneration: Int
    ) async throws -> StudyManualCardDraft {
        let startingDraftRevision = draftRevisions[id, default: 0]
        let draft: StudyManualCardDraft = try await api.request(
            "/api/study/card-drafts/\(id)"
        )
        try ensureActive(userID: userID, generation: operationGeneration)
        let latest = drafts.first { $0.id == draft.id }
        let changedDuringFetch = draftRevisions[id, default: 0]
            != startingDraftRevision
        if changedDuringFetch, latest == nil
        {
            throw CancellationError()
        }
        if let latest {
            if latest.updatedAt > draft.updatedAt
                || (changedDuringFetch && latest.updatedAt == draft.updatedAt)
            {
                return latest
            }
        }
        replace(draft)
        return draft
    }

    func replace(_ draft: StudyManualCardDraft) {
        drafts.removeAll { $0.id == draft.id }
        drafts.append(draft)
        drafts.sort { $0.createdAt > $1.createdAt }
        revision += 1
        draftRevisions[draft.id, default: 0] += 1
    }

    func pendingCreateRequests() -> [CreateStudyManualCardDraftRequest] {
        guard let activeUserID else { return [] }
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.userID == activeUserID
                    && $0.kind == "draftCreate"
                    && $0.lastError == nil
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return ((try? context.fetch(descriptor)) ?? []).compactMap {
            try? StorageCodec.decoder.decode(
                CreateStudyManualCardDraftRequest.self,
                from: $0.payload
            )
        }
    }

    @discardableResult
    func stageCreate(
        _ request: CreateStudyManualCardDraftRequest
    ) throws -> PendingMutation {
        guard let userID = activeUserID else { throw CancellationError() }
        if let existing = try pendingCreate(for: request.id, userID: userID) {
            existing.payload = try StorageCodec.encoder.encode(request)
            existing.lastError = nil
            try context.save()
            return existing
        }
        let mutation = PendingMutation(
            kind: "draftCreate",
            userID: userID,
            resourceID: request.id,
            payload: try StorageCodec.encoder.encode(request)
        )
        context.insert(mutation)
        try context.save()
        return mutation
    }

    @discardableResult
    func queueCreate(
        _ request: CreateStudyManualCardDraftRequest
    ) async throws -> StudyManualCardDraft {
        let mutation = try stageCreate(request)
        return try await runCreate(mutation)
    }

    @discardableResult
    func stageCommit(
        draftID: String,
        cardID: String? = nil
    ) throws -> PendingMutation {
        guard let userID = activeUserID else { throw CancellationError() }
        if let existing = try pendingCommit(for: draftID, userID: userID) {
            if existing.kind == "draftCommitRejected" {
                existing.kind = "draftCommit"
                existing.attemptCount = 0
                existing.lastAttemptAt = nil
                existing.lastError = nil
                try context.save()
            }
            return existing
        }
        let mutation = PendingMutation(
            kind: "draftCommit",
            userID: userID,
            resourceID: draftID,
            payload: try StorageCodec.encoder.encode(
                CreateCardFromStudyManualDraftRequest(
                    id: cardID ?? ClientIdentifier.ulid()
                )
            )
        )
        context.insert(mutation)
        try context.save()
        return mutation
    }

    func commit(
        draftID: String,
        onCommittedCard: @escaping (StudyCard) async throws -> Void
    ) async throws {
        let mutation = try stageCommit(draftID: draftID)
        try await runCommit(mutation, onCommittedCard: onCommittedCard)
    }

    func retryPendingMutations(
        onCommittedCard: @escaping (StudyCard) async throws -> Void
    ) async throws {
        guard let userID = activeUserID else { return }
        let operationGeneration = generation
        var firstError: (any Error)?
        do {
            try await retryPendingCreates()
        } catch {
            firstError = error
        }
        if activeUserID == userID, generation == operationGeneration {
            do {
                try await retryPendingCommits(onCommittedCard: onCommittedCard)
            } catch {
                firstError = firstError ?? error
            }
        } else {
            firstError = firstError ?? CancellationError()
        }
        if let firstError {
            throw firstError
        }
    }

    func retryPendingCreates() async throws {
        guard let userID = activeUserID else { return }
        let operationGeneration = generation
        try await retryPending(
            kind: "draftCreate",
            userID: userID,
            generation: operationGeneration
        ) { mutation in
            _ = try await self.runCreate(mutation)
        }
    }

    func retryPendingCommits(
        onCommittedCard: @escaping (StudyCard) async throws -> Void
    ) async throws {
        guard let userID = activeUserID else { return }
        let operationGeneration = generation
        try await retryPending(
            kind: "draftCommit",
            userID: userID,
            generation: operationGeneration
        ) { mutation in
            try await self.runCommit(
                mutation,
                onCommittedCard: onCommittedCard
            )
        }
    }

    private func retryPending(
        kind: String,
        userID: Int,
        generation: Int,
        operation: @MainActor (PendingMutation) async throws -> Void
    ) async throws {
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.userID == userID
                    && $0.kind == kind
                    && $0.lastError == nil
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        var firstError: (any Error)?
        for mutation in try context.fetch(descriptor) {
            do {
                try ensureActive(userID: userID, generation: generation)
                try await operation(mutation)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    func hasPendingCommit(for draftID: String) -> Bool {
        recoveryState(for: draftID) != .none
    }

    func recoveryState(for draftID: String) -> ManualDraftCommitRecoveryState {
        guard let userID = activeUserID else { return .none }
        guard
            let mutation = try? pendingCommit(for: draftID, userID: userID),
            let request = try? StorageCodec.decoder.decode(
                CreateCardFromStudyManualDraftRequest.self,
                from: mutation.payload
            )
        else {
            return .none
        }
        if mutation.kind == "draftCommitRejected" {
            return .rejected
        }
        let originalCardID = request.id
        let normalizedCardID = originalCardID.lowercased()
        var descriptor = FetchDescriptor<LocalCardRecord>(
            predicate: #Predicate {
                $0.userID == userID
                    && ($0.id == normalizedCardID || $0.id == originalCardID)
            }
        )
        descriptor.fetchLimit = 1
        let hasConfirmedCard = ((try? context.fetch(descriptor)) ?? []).isEmpty == false
        return hasConfirmedCard ? .cleanupPending : .outcomeUnknown
    }

    func deleteDraft(id: String) async throws {
        guard let userID = activeUserID else { throw CancellationError() }
        let operationGeneration = generation
        let pending = try pendingCommit(for: id, userID: userID)
        if let pending, pending.kind != "draftCommitRejected" {
            throw PendingManualDraftCommitError()
        }
        try await api.request(
            "/api/study/card-drafts/\(id)",
            method: "DELETE"
        )
        let operationIsStillActive = activeUserID == userID
            && generation == operationGeneration
        if let pending {
            context.delete(pending)
            try context.save()
        }
        guard operationIsStillActive else { throw CancellationError() }
        removeDraft(id: id)
    }

    private func fetchAll(
        userID: Int,
        generation: Int
    ) async throws -> [StudyManualCardDraft] {
        var result: [StudyManualCardDraft] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            try ensureActive(userID: userID, generation: generation)
            var query = [URLQueryItem(name: "limit", value: "200")]
            if let cursor {
                query.append(URLQueryItem(name: "cursor", value: cursor))
            }
            let response: StudyManualCardDraftListResponse = try await api.request(
                "/api/study/card-drafts",
                query: query
            )
            try ensureActive(userID: userID, generation: generation)
            result.append(contentsOf: response.drafts)
            cursor = response.nextCursor
            if let nextCursor = cursor, !seenCursors.insert(nextCursor).inserted {
                cursor = nil
            }
        } while cursor != nil
        return result
    }

    private func runCreate(
        _ mutation: PendingMutation
    ) async throws -> StudyManualCardDraft {
        let mutationID = mutation.id
        if let task = createTasks[mutationID] {
            return try await task.value
        }
        guard mutation.userID == activeUserID else { throw CancellationError() }
        let userID = mutation.userID
        let operationGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            return try await performCreate(
                mutation,
                userID: userID,
                generation: operationGeneration
            )
        }
        createTasks[mutationID] = task
        defer {
            if generation == operationGeneration {
                createTasks[mutationID] = nil
            }
        }
        return try await task.value
    }

    private func performCreate(
        _ mutation: PendingMutation,
        userID: Int,
        generation: Int
    ) async throws -> StudyManualCardDraft {
        try ensureActive(userID: userID, generation: generation)
        let request = try StorageCodec.decoder.decode(
            CreateStudyManualCardDraftRequest.self,
            from: mutation.payload
        )
        mutation.attemptCount += 1
        mutation.lastAttemptAt = .now
        mutation.lastError = nil
        try context.save()

        let serverDraft: StudyManualCardDraft
        do {
            serverDraft = try await api.request(
                "/api/study/card-drafts",
                method: "POST",
                body: request
            )
            try ensureActive(userID: userID, generation: generation)
        } catch {
            try ensureActive(userID: userID, generation: generation)
            if case let APIClientError.rejected(status, _) = error,
               isPermanentCreateRejection(status: status)
            {
                mutation.lastError = error.localizedDescription
            } else {
                mutation.lastError = nil
            }
            try? context.save()
            throw error
        }

        context.delete(mutation)
        try context.save()
        replace(serverDraft)
        return serverDraft
    }

    private func runCommit(
        _ mutation: PendingMutation,
        onCommittedCard: @escaping (StudyCard) async throws -> Void
    ) async throws {
        let mutationID = mutation.id
        if let task = commitTasks[mutationID] {
            return try await task.value
        }
        guard mutation.userID == activeUserID else { throw CancellationError() }
        let userID = mutation.userID
        let operationGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await performCommit(
                mutation,
                userID: userID,
                generation: operationGeneration,
                onCommittedCard: onCommittedCard
            )
        }
        commitTasks[mutationID] = task
        defer {
            if generation == operationGeneration {
                commitTasks[mutationID] = nil
            }
        }
        try await task.value
    }

    private func performCommit(
        _ mutation: PendingMutation,
        userID: Int,
        generation: Int,
        onCommittedCard: (StudyCard) async throws -> Void
    ) async throws {
        try ensureActive(userID: userID, generation: generation)
        let request = try StorageCodec.decoder.decode(
            CreateCardFromStudyManualDraftRequest.self,
            from: mutation.payload
        )
        let card = try await createCanonicalCard(
            from: mutation,
            request: request,
            userID: userID,
            generation: generation
        )

        // Persist the confirmed canonical card before deleting its transient
        // draft so an interrupted cleanup cannot lose the created card.
        try await onCommittedCard(card)
        try ensureActive(userID: userID, generation: generation)
        try await cleanupCommittedDraft(
            mutation,
            userID: userID,
            generation: generation
        )
    }

    private func createCanonicalCard(
        from mutation: PendingMutation,
        request: CreateCardFromStudyManualDraftRequest,
        userID: Int,
        generation: Int
    ) async throws -> StudyCard {
        do {
            // learning-os intentionally exposes the unwrapped ConvoLab
            // compatibility payload for manual draft commits.
            let card: StudyCard = try await api.request(
                "/api/study/card-drafts/\(mutation.resourceID)/create-card",
                method: "POST",
                body: request
            )
            try ensureActive(userID: userID, generation: generation)
            return card
        } catch let rejection as APIClientError {
            let isPermanent = await commitRejectionIsPermanent(
                rejection,
                mutation: mutation,
                clientCardID: request.id,
                userID: userID,
                generation: generation
            )
            try ensureActive(userID: userID, generation: generation)
            if isPermanent {
                // A same-client-ID idempotent retry returns 200. For a 409,
                // canonical draft state distinguishes a transient generating
                // response from a terminal different-card-ID conflict.
                mutation.kind = "draftCommitRejected"
            }
            recordCommitFailure(
                rejection,
                on: mutation,
                isPermanentRejection: isPermanent
            )
            try context.save()
            throw rejection
        } catch {
            try ensureActive(userID: userID, generation: generation)
            recordCommitFailure(error, on: mutation)
            try context.save()
            throw error
        }
    }

    private func commitRejectionIsPermanent(
        _ rejection: APIClientError,
        mutation: PendingMutation,
        clientCardID: String,
        userID: Int,
        generation: Int
    ) async -> Bool {
        guard case let .rejected(status, _) = rejection else { return false }
        guard status == 409 else {
            return isPermanentCommitRejection(status: status)
        }
        return await draftHasDifferentCommittedCardID(
            draftID: mutation.resourceID,
            clientCardID: clientCardID,
            userID: userID,
            generation: generation
        )
    }

    private func cleanupCommittedDraft(
        _ mutation: PendingMutation,
        userID: Int,
        generation: Int
    ) async throws {
        do {
            try await api.request(
                "/api/study/card-drafts/\(mutation.resourceID)",
                method: "DELETE"
            )
            try ensureActive(userID: userID, generation: generation)
        } catch let APIClientError.rejected(status, _)
            where [404, 410].contains(status)
        {
            try ensureActive(userID: userID, generation: generation)
        } catch {
            try ensureActive(userID: userID, generation: generation)
            recordCleanupFailure(on: mutation)
            try context.save()
            throw error
        }
        context.delete(mutation)
        removeDraft(id: mutation.resourceID)
        try context.save()
    }

    private func pendingCreate(
        for draftID: String,
        userID: Int
    ) throws -> PendingMutation? {
        var descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.userID == userID
                    && $0.kind == "draftCreate"
                    && $0.resourceID == draftID
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func pendingCommit(
        for draftID: String,
        userID: Int
    ) throws -> PendingMutation? {
        var descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.userID == userID
                    && ($0.kind == "draftCommit" || $0.kind == "draftCommitRejected")
                    && $0.resourceID == draftID
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func draftHasDifferentCommittedCardID(
        draftID: String,
        clientCardID: String,
        userID: Int,
        generation: Int
    ) async -> Bool {
        guard (try? ensureActive(userID: userID, generation: generation)) != nil,
              let draft = try? await performFetch(
                id: draftID,
                userID: userID,
                generation: generation
              )
        else {
            return false
        }
        guard (try? ensureActive(userID: userID, generation: generation)) != nil else {
            return false
        }
        guard let committedCardID = draft.committedCardId else { return false }
        return committedCardID.lowercased() != clientCardID.lowercased()
    }

    private func recordCommitFailure(
        _ error: any Error,
        on mutation: PendingMutation,
        isPermanentRejection override: Bool? = nil
    ) {
        mutation.attemptCount += 1
        mutation.lastAttemptAt = .now
        let isPermanent: Bool
        if let override {
            isPermanent = override
        } else if case let APIClientError.rejected(status, _) = error {
            isPermanent = isPermanentCommitRejection(status: status)
        } else {
            isPermanent = false
        }
        mutation.lastError = isPermanent ? error.localizedDescription : nil
    }

    private func recordCleanupFailure(on mutation: PendingMutation) {
        mutation.attemptCount += 1
        mutation.lastAttemptAt = .now
        // The card is already canonical. Every cleanup failure stays eligible
        // for retry, regardless of its HTTP status.
        mutation.lastError = nil
    }

    private func removeDraft(id: String) {
        drafts.removeAll { $0.id == id }
        revision += 1
        draftRevisions[id, default: 0] += 1
    }

    // Internal so concurrency tests can model a completed list refresh while
    // an older individual-draft request is still in flight.
    func applyFetchedDrafts(_ fetched: [StudyManualCardDraft]) {
        let currentByID = Dictionary(
            drafts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let fetchedByID = Dictionary(
            fetched.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for id in Set(currentByID.keys).union(fetchedByID.keys)
        where draftVersionChanged(
            from: currentByID[id],
            to: fetchedByID[id]
        ) {
            draftRevisions[id, default: 0] += 1
        }
        drafts = fetched.sorted { $0.createdAt > $1.createdAt }
        revision += 1
    }

    private func draftVersionChanged(
        from current: StudyManualCardDraft?,
        to fetched: StudyManualCardDraft?
    ) -> Bool {
        guard let current, let fetched else { return current != fetched }
        return current.updatedAt != fetched.updatedAt
            || current.status != fetched.status
            || current.committedCardId != fetched.committedCardId
    }

    private func isPermanentCommitRejection(status: Int) -> Bool {
        [400, 404, 410, 422].contains(status)
    }

    private func isPermanentCreateRejection(status: Int) -> Bool {
        [400, 404, 409, 410, 422].contains(status)
    }

    private func ensureActive(userID: Int, generation: Int) throws {
        try Task.checkCancellation()
        guard activeUserID == userID, self.generation == generation else {
            throw CancellationError()
        }
    }
}
