import Foundation

extension StudyStore {
    func refreshPiles() async {
        guard let userID = activeUserID, let token = api.accessToken else { return }
        let generation = accountActivationGeneration
        let requestID = UUID()
        piles.refreshID = requestID
        piles.isRefreshing = true
        piles.errorMessage = nil
        defer { if piles.refreshID == requestID { piles.isRefreshing = false } }
        do {
            let catalog = try await fetchPiles(token: token)
            guard activeUserID == userID, accountActivationGeneration == generation,
                  piles.refreshID == requestID else { return }
            piles.catalog = catalog
        } catch {
            guard activeUserID == userID, accountActivationGeneration == generation,
                  piles.refreshID == requestID else { return }
            piles.errorMessage = error.localizedDescription
        }
    }

    private func fetchPiles(token: String) async throws -> StudyPileCatalog {
        var cursor = 0
        var piles: [StudyPile] = []
        while true {
            var page: StudyPileCatalog = try await api.request(
                "/api/study/piles", query: [URLQueryItem(name: "limit", value: "100"),
                                          URLQueryItem(name: "cursor", value: String(cursor))],
                authorizationToken: token
            )
            piles.append(contentsOf: page.piles)
            guard let next = page.nextCursor else {
                page.piles = piles
                return page
            }
            guard next > cursor else { throw APIClientError.invalidResponse }
            cursor = next
        }
    }

    func savePile(id: String, update: StudyPileUpdate, pileID: String? = nil) async throws {
        guard let userID = activeUserID, let token = api.accessToken else { throw APIClientError.invalidResponse }
        guard ClientIdentifier.isULID(id), pileID.map(ClientIdentifier.isULID) ?? true else {
            throw APIClientError.invalidResponse
        }
        let generation = accountActivationGeneration
        let path = pileID.map { "/api/study/piles/\($0.lowercased())/chapters/\(id.lowercased())" }
            ?? "/api/study/piles/\(id.lowercased())"
        try await api.request(path, method: "PUT", body: update, authorizationToken: token)
        guard activeUserID == userID, accountActivationGeneration == generation else { return }
        await refreshPiles()
        await refreshOverview()
    }
}
