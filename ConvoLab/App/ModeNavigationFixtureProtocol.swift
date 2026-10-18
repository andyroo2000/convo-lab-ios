#if DEBUG
import Foundation

nonisolated final class ModeNavigationFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let body = responseBody(path: url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func responseBody(path: String) -> String? {
        if request.httpMethod == "PUT", path.hasPrefix("/api/reading-progress/") {
            return "{\"position\":\(requestBody())}"
        }
        return Self.responses[path]
    }

    private func requestBody() -> String {
        if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "null" }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return String(decoding: body, as: UTF8.self)
    }

    private static let responses: [String: String] = [
        "/api/me": #"{"data":{"id":-205,"name":"Navigation fixture","email":"navigation@ui-tests.invalid","email_verified_at":null}}"#,
        "/api/study/new-queue": queue,
        "/api/study/new-queue/reorder": queue,
        "/api/study/card-drafts": #"{"drafts":[],"total":0,"limit":20,"nextCursor":null}"#,
        "/api/study/learning-items": #"{"items":[],"limit":20,"nextCursor":null}"#,
        "/api/reading-library": #"{"data":[{"id":"navigation-book","title":"森の本","kind":"book"}],"current_page":1,"last_page":1}"#,
        "/api/reading-books/navigation-book": #"{"id":"navigation-book","title":"森の本","revision":1,"readings":[{"id":"navigation-reading","title":"小さな犬","author":"著者","revision":1,"pageCount":2,"pageNumbers":[24,25]}]}"#,
        "/api/reading-progress": #"{"continue":null}"#,
        "/api/reading-progress/navigation-reading": #"{"position":null}"#,
        "/api/convolab/readings/navigation-reading": document,
    ]

    private static let queue = #"""
    {"items":[
      {"id":"01JNAVIGATIONCARD0000000001","noteId":"01JNAVIGATIONNOTE0000000001","cardType":"recognition","displayText":"First queued card","meaning":"first","queuePosition":0,"createdAt":"2026-10-17T00:00:00Z","updatedAt":"2026-10-17T00:00:00Z"},
      {"id":"01JNAVIGATIONCARD0000000002","noteId":"01JNAVIGATIONNOTE0000000002","cardType":"recognition","displayText":"Second queued card","meaning":"second","queuePosition":1,"createdAt":"2026-10-17T00:00:00Z","updatedAt":"2026-10-17T00:00:00Z"}
    ],"total":2,"limit":100,"nextCursor":null}
    """#

    private static let document = #"""
    {"id":"navigation-reading","title":"小さな犬","revision":1,"voiceId":"fixture","voiceName":"Narrator","document":{"title":"小さな犬","author":"著者","pages":[
      {"number":24,"kind":"text","columns":[[[0,"森[もり]に犬[いぬ]がいました。"]]]},
      {"number":25,"kind":"text","columns":[[[1,"犬[いぬ]は家[いえ]へ帰[かえ]りました。"]]]}
    ],"sentences":[{"text":"森に犬がいました。","translation":"There was a dog in the forest."},{"text":"犬は家へ帰りました。","translation":"The dog went home."}]}}
    """#
}
#endif
