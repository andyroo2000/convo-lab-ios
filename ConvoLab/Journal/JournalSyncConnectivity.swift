import Network

@MainActor
final class JournalSyncConnectivity {
    nonisolated deinit {}
    private let monitor = NWPathMonitor()
    private var stopped = false

    init(store: JournalStore) {
        monitor.pathUpdateHandler = { [weak self, weak store] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard self?.stopped == false else { return }
                store?.synchronization.reconnect()
                await store?.synchronizeDrafts()
            }
        }
        monitor.start(queue: DispatchQueue(label: "JournalSyncConnectivity"))
    }

    func stop() { stopped = true; monitor.pathUpdateHandler = nil; monitor.cancel() }
}
