import Foundation

@Observable
final class StudyPileState {
    var catalog: StudyPileCatalog?
    var errorMessage: String?
    var isRefreshing = false
    @ObservationIgnored var refreshID: UUID?

    func reset() {
        catalog = nil
        errorMessage = nil
        isRefreshing = false
        refreshID = nil
    }
}
