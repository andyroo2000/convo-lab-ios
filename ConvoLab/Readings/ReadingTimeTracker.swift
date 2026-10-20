import Foundation

/// Owns only the automatic interval created by this reader. Other activities
/// and manual sessions can replace it without being stopped by stale cleanup.
@MainActor
final class ReadingTimeTracker {
    private var store: StudyTimeStore?
    private var sessionID: String?

    func update(title: String?, store nextStore: StudyTimeStore?, at date: Date = .now) {
        if store !== nextStore {
            guard stop(at: date) else { return }
            store = nextStore
        }
        guard let title, let store else {
            stop(at: date)
            return
        }
        // Once another activity takes over, page/load callbacks from this
        // reader must not steal it back. A later appearance starts a new lease.
        guard sessionID == nil || store.active == nil else { return }
        start(title: title, in: store, at: date)
    }

    private func start(title: String, in store: StudyTimeStore, at date: Date) {
        // Same-title readings still need distinct ownership. Do not adopt an
        // existing reading interval that another reader may later tear down.
        if store.active?.activity == .reading, store.active?.source == .automatic {
            guard store.stop(activity: .reading, source: .automatic, at: date) else { return }
        }
        let name = String(title.unicodeScalars.prefix(120))
        guard store.start(activity: .reading, source: .automatic, name: name, at: date),
              let active = store.active, active.activity == .reading, active.source == .automatic
        else { return }
        sessionID = active.clientSessionID
    }

    @discardableResult
    private func stop(at date: Date) -> Bool {
        if let sessionID, store?.active?.clientSessionID == sessionID {
            guard store?.stop(activity: .reading, source: .automatic, at: date) == true else { return false }
        }
        sessionID = nil
        return true
    }
}
