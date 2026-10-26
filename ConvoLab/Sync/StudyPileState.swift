import Foundation

@Observable
final class StudyPileState {
    var catalog: StudyPileCatalog?
    var errorMessage: String?
    var isRefreshing = false
    @ObservationIgnored var refreshID: UUID?

    // No actor-bound cleanup is required. Avoid Swift 6.2's nested isolated-deinit
    // runtime crash when a StudyStore releases this observable state synchronously.
    nonisolated deinit {}

    func reset() {
        catalog = nil
        errorMessage = nil
        isRefreshing = false
        refreshID = nil
    }
}
