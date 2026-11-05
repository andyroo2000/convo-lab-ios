import Foundation

@Observable
final class StudyPileState {
    var catalog: StudyPileCatalog?
    var errorMessage: String?
    var isRefreshing = false
    @ObservationIgnored var refreshID: UUID?
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSaves: Set<UUID> = []

    var hasPendingSaves: Bool { !pendingSaves.isEmpty }

    func beginSave() -> UUID {
        invalidateRefresh()
        let id = UUID()
        pendingSaves.insert(id)
        return id
    }

    func finishSave(_ id: UUID) -> Bool {
        pendingSaves.remove(id) != nil && pendingSaves.isEmpty
    }

    func invalidateRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        isRefreshing = false
    }

    func reset() {
        invalidateRefresh()
        pendingSaves.removeAll()
        catalog = nil
        errorMessage = nil
    }
}
