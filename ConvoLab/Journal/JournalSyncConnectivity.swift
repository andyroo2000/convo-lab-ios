import Network

@MainActor
final class JournalSyncConnectivity {
    nonisolated deinit {}
    private let monitor = NWPathMonitor()

    init(store: JournalStore) {
        monitor.pathUpdateHandler = { [weak store] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                store?.synchronization.reconnect()
                await store?.synchronizeDrafts()
            }
        }
        monitor.start(queue: DispatchQueue(label: "JournalSyncConnectivity"))
    }

    func stop() { monitor.cancel() }
}
