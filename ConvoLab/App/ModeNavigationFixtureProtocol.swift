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
        if let journal = JournalReplyNavigationFixture.shared.response(path: path, method: request.httpMethod,
            body: requestBody(), initial: Self.journalAnalysis, entry: Self.journalEntry) { return journal }
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
        "/api/journal/entries": "{\"data\":[\(journalEntry)],\"nextCursor\":null}",
        "/api/journal/entries/01arz3ndektsv4rrffq69g5fav": "{\"data\":\(journalEntry)}",
        "/api/journal/entries/01arz3ndektsv4rrffq69g5fav/analysis": "{\"data\":\(journalAnalysis),\"entry\":\(journalEntry)}",
        "/api/journal/voices": #"{"data":[{"id":"haru","name":"Haru (M)"},{"id":"yua","name":"Yua (F)"}]}"#,
        "/api/journal/entries/01arz3ndektsv4rrffq69g5fav/audio": #"{"data":{"voiceId":"yua","hasAudio":true}}"#,
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

    private static let journalAnalysis = #"""
    {"id":"01arz3ndektsv4rrffq69g5faw","sourceVersion":1,"status":"ready","error":null,"updatedAt":"now","replyRevision":0,"result":{
      "title":"A movie night","correctedText":"映画を見ました。","correctedReading":"映画[えいが]を見[み]ました。",
      "question":"誰と見ましたか。","questionReading":"誰[だれ]と見[み]ましたか。","questionTranslation":"Who did you watch it with?",
      "segments":[{"text":"映画を見た。","reading":"映画[えいが]を見[み]た。","kind":"optional",
        "suggestion":"映画を見ました。","suggestionReading":"映画[えいが]を見[み]ました。",
        "replacement":"映画を見ました。","replacementReading":"映画[えいが]を見[み]ました。",
        "explanation":"見ました is the polite past form.","explanationReading":"見[み]ました is the polite past form."}]}}
    """#

    private static let journalEntry = #"{"id":"01arz3ndektsv4rrffq69g5fav","title":"A movie night","body":"映画を見た。","entryDate":"2026-11-12","version":1,"createdAt":"now","updatedAt":"now"}"#

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
