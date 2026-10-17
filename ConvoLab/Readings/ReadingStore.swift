import Foundation

@Observable
final class ReadingStore {
    let api: APIClient
    private let token: String?
    private let storage: ReadingLocalStorage
    private(set) var snapshot: ReadingSnapshot
    private(set) var page = 1
    private(set) var isLoading = false
    var errorMessage: String?
    private var loadGeneration = 0
    private var isSyncing = false

    init(api: APIClient, userID: Int) {
        self.api = api
        token = api.accessToken
        storage = ReadingLocalStorage(userID: userID)
        do {
            snapshot = try storage.load()
        } catch {
            snapshot = ReadingSnapshot()
            errorMessage = "Saved readings could not be opened: \(error.localizedDescription)"
        }
    }

    var library: ReadingLibraryPage? { snapshot.library[page] }
    var resume: ReadingContinue? { snapshot.resume }
    func document(_ id: String) -> ReadingDetail? { snapshot.documents[id] }
    func book(_ id: String) -> ReadingBook? { snapshot.books[id] }
    func position(_ id: String) -> ReadingPosition? { snapshot.positions[id] }

    func checkSession() throws {
        guard token != nil, api.accessToken == token else {
            throw APIClientError.rejected(status: 401, message: "Your session changed. Reopen Readings to continue.")
        }
        try Task.checkCancellation()
    }

    func loadLibrary(page requestedPage: Int? = nil) async {
        let targetPage = requestedPage ?? page
        if snapshot.library[targetPage] != nil { page = targetPage }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            try checkSession()
            await synchronizePositions()
            let result: ReadingLibraryPage = try await api.request("/api/reading-library", query: [.init(name: "page", value: String(targetPage))])
            try checkSession()
            guard generation == loadGeneration else { return }
            page = targetPage
            snapshot.library[targetPage] = result
            persist()
            let continuation: ReadingContinueResponse = try await api.request("/api/reading-progress")
            try checkSession()
            acceptResume(continuation.continue)
            persist()
        } catch { report(error) }
    }

    func loadBook(_ id: String) async {
        do {
            try checkSession()
            let result: ReadingBook = try await api.request("/api/reading-books/\(id)")
            try checkSession()
            snapshot.books[id] = result
            persist()
        } catch { report(error) }
    }

    func loadDocument(_ id: String) async {
        do {
            try checkSession()
            let result: ReadingDetail = try await api.request("/api/convolab/readings/\(id)")
            try checkSession()
            snapshot.documents[id] = result
            await synchronizePositions()
            let position: ReadingPositionResponse = try await api.request("/api/reading-progress/\(id)")
            try checkSession()
            if let position = position.position { acceptPosition(position) }
            persist()
        } catch { report(error) }
    }

    func record(_ reading: ReadingDetail, pageNumber: Int, sentence: Int?) {
        guard (try? checkSession()) != nil else { return }
        let position = ReadingPosition(readingId: reading.id, pageNumber: pageNumber, sentenceIndex: sentence,
                                       readingRevision: reading.revision, eventId: UUID().uuidString.lowercased(), readAt: Date())
        snapshot.positions[reading.id] = position
        snapshot.pending[reading.id] = position
        snapshot.rejected?.removeValue(forKey: reading.id)
        snapshot.resume = ReadingContinue(id: reading.id, title: reading.title, position: position)
        persistPositions()
    }

    func synchronizePositions() async {
        guard !isSyncing else { return }
        isSyncing = true
        var rejected = Set<String>()
        var failure: String?
        defer {
            isSyncing = false
            if let failure { errorMessage = failure }
        }
        while let pending = snapshot.pending.values.filter({ !rejected.contains($0.readingId) }).min(by: { $0.readAt < $1.readAt }) {
            do {
                try checkSession()
                let result: ReadingPositionResponse = try await api.request("/api/reading-progress/\(pending.readingId)", method: "PUT", body: pending)
                try checkSession()
                guard let acknowledged = result.position else { throw APIClientError.invalidResponse }
                if snapshot.pending[pending.readingId]?.eventId == pending.eventId {
                    snapshot.pending.removeValue(forKey: pending.readingId)
                }
                acceptPosition(acknowledged)
                errorMessage = nil
                persistPositions()
            } catch {
                report(error)
                failure = errorMessage
                guard isPositionRejection(error) else { return }
                rejected.insert(pending.readingId)
                retainRejected(pending)
            }
        }
    }

    private func retainRejected(_ position: ReadingPosition) {
        guard snapshot.pending[position.readingId]?.eventId == position.eventId else { return }
        if snapshot.rejected == nil { snapshot.rejected = [:] }
        snapshot.rejected?[position.readingId] = position
        snapshot.pending.removeValue(forKey: position.readingId)
        persistPositions()
    }

    private func isPositionRejection(_ error: any Error) -> Bool {
        guard case let APIClientError.rejected(status, _) = error else { return false }
        return [400, 403, 404, 409, 422].contains(status)
    }

    func resource(_ path: String, key: String, method: String = "GET") async throws -> Data {
        try checkSession()
        if let cached = try storage.resource(key: key) { return cached }
        let data = try await api.readingResource(path, method: method)
        try checkSession()
        do { try storage.saveResource(data, key: key) }
        catch { errorMessage = "This media could not be saved for offline use." }
        return data
    }

    func invalidateResource(key: String) {
        try? storage.removeResource(key: key)
    }

    private func acceptPosition(_ position: ReadingPosition) {
        if let local = snapshot.positions[position.readingId], local.isNewer(than: position) { return }
        snapshot.positions[position.readingId] = position
        if let reading = snapshot.documents[position.readingId] {
            acceptResume(ReadingContinue(id: reading.id, title: reading.title, position: position))
        }
    }

    private func acceptResume(_ item: ReadingContinue?) {
        guard let item else { return }
        if let local = snapshot.resume, local.position.isNewer(than: item.position) { return }
        snapshot.resume = item
    }

    private func persistPositions() {
        do { try storage.savePositions(snapshot) }
        catch { errorMessage = "Could not save your reading position on this device: \(error.localizedDescription)" }
    }

    private func persist() {
        do { try storage.save(snapshot) }
        catch { errorMessage = "Could not save your reading position on this device: \(error.localizedDescription)" }
    }

    private func report(_ error: any Error) {
        if error is CancellationError { return }
        errorMessage = error.localizedDescription
    }
}
