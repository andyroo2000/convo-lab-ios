#if DEBUG
import SwiftData
import SwiftUI

struct UITestReadingFixture: View {
    @State private var api: APIClient
    @State private var timeStore: StudyTimeStore?
    @State private var timeContainer: ModelContainer?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadingFixtureProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://readings.invalid")!, session: URLSession(configuration: configuration))
        api.setAccessToken("reading-fixture")
        _api = State(initialValue: api)
        if ProcessInfo.processInfo.arguments.contains("-ui-test-reading-time") {
            let container = try! StudyTimePersistence.makeContainer(inMemory: true)
            let timeStore = StudyTimeStore(api: api, context: container.mainContext)
            timeStore.activate(userID: -204)
            _timeStore = State(initialValue: timeStore)
            _timeContainer = State(initialValue: container)
        } else {
            _timeStore = State(initialValue: nil)
            _timeContainer = State(initialValue: nil)
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-test-reset") {
            try? ReadingLocalStorage.remove(userID: -204)
        }
    }

    var body: some View {
        TabView {
            Tab("Readings", systemImage: "book.closed") {
                ReadingLibraryView(api: api, userID: -204, beforeAudio: {})
                    .environment(timeStore)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .modifier(AppModeHeader(selection: .constant(.readings)))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let timeStore { trackingProbe(timeStore) }
        }
    }

    private func trackingProbe(_ store: StudyTimeStore) -> some View {
        HStack {
            Text("Reading activity")
                .accessibilityIdentifier("reading-time-active")
                .accessibilityValue(activeDescription(store.active))
            Text("Completed intervals")
                .accessibilityIdentifier("reading-time-completed")
                .accessibilityValue(String(store.sessions.count))
            Text("Last finish")
                .accessibilityIdentifier("reading-time-finished-at")
                .accessibilityValue(String(store.sessions.map(\.endedAt).max()?.timeIntervalSince1970 ?? 0))
        }
        .font(.caption2)
        .padding(4)
    }

    private func activeDescription(_ active: StudyTimeActiveSession?) -> String {
        guard let active else { return "idle" }
        return [active.activity.rawValue, active.source.rawValue, active.category.rawValue,
                active.name ?? "", active.clientSessionID].joined(separator: "|")
    }
}

private nonisolated final class ReadingFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        // Keep the lifecycle fixture offline so completed intervals stay in the
        // real local outbox instead of relying on a simulated server response.
        if url.path.hasPrefix("/api/study/") {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let body = request.httpMethod == "PUT" ? acknowledgement() : Self.response(for: url.path)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func acknowledgement() -> String {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return "{\"position\":\(String(data: data, encoding: .utf8) ?? "null")}"
    }

    private static func response(for path: String) -> String {
        switch path {
        case "/api/reading-library":
            return #"{"data":[{"id":"collection","title":"森の本","kind":"book"},{"id":"reading","title":"小さな犬","kind":"reading"}],"current_page":1,"last_page":1}"#
        case "/api/reading-books/collection":
            return #"{"id":"collection","title":"森の本","revision":1,"readings":[{"id":"reading","title":"小さな犬","author":"著者","revision":1,"pageCount":2,"pageNumbers":[24,25]}]}"#
        case "/api/reading-progress": return #"{"continue":null}"#
        case "/api/reading-progress/reading": return #"{"position":null}"#
        default: return document
        }
    }

    private static let document = #"""
    {"id":"reading","title":"小さな犬","revision":1,"voiceId":"fishaudio:9bf6608381a34f47ada3753f2e9f9381","voiceName":"ナレーター男性","document":{"title":"小さな犬","author":"著者","pages":[{"number":24,"kind":"text","columns":[[[0,"　森[もり]の中[なか]に、小[ちい]さな犬[いぬ]がいました。"],[1,"犬[いぬ]は空[そら]を見[み]ました。"]],[[2,"　風[かぜ]が静[しず]かに吹[ふ]いていました。"]]]},{"number":25,"kind":"text","columns":[[[3,"犬[いぬ]は家[いえ]へ帰[かえ]りました。"]]]}],"sentences":[{"text":"森の中に、小さな犬がいました。","translation":"There was a little dog in the forest."},{"text":"犬は空を見ました。","translation":"The dog looked at the sky."},{"text":"風が静かに吹いていました。","translation":"The wind was blowing gently."},{"text":"犬は家へ帰りました。","translation":"The dog went home."}]}}
    """#
}
#endif
