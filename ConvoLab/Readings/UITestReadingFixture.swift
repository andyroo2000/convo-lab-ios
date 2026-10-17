#if DEBUG
import SwiftUI

struct UITestReadingFixture: View {
    @State private var api: APIClient

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadingFixtureProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://readings.invalid")!, session: URLSession(configuration: configuration))
        api.setAccessToken("reading-fixture")
        _api = State(initialValue: api)
        if ProcessInfo.processInfo.arguments.contains("-ui-test-reset") {
            try? ReadingLocalStorage.remove(userID: -204)
        }
    }

    var body: some View {
        ReadingLibraryView(api: api, userID: -204, beforeAudio: {})
    }
}

private nonisolated final class ReadingFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
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
