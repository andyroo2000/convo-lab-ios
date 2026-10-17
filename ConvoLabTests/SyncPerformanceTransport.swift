import Foundation

/// A deterministic HTTP boundary: production URLSession, API decoding, sync,
/// SQLite persistence, and media writes remain in the measured path.
nonisolated final class SyncPerformanceTransport: @unchecked Sendable {
    struct Snapshot: Sendable {
        var cards: [String: Data]
        var feedEntries: [Entry]
        var session: Data
        var reserve: Data
    }

    struct Entry: Codable, Sendable {
        let checkpoint: Int64
        let resource_id: String
        let operation: String
    }

    private struct IDs: Decodable { let ids: [String] }
    private let lock = NSLock()
    private var snapshot: Snapshot
    private var traffic = SyncPerformanceTraffic()
    let requestLatencyMS: Int
    let mediaBytesPerItem: Int

    init(snapshot: Snapshot, requestLatencyMS: Int, mediaBytesPerItem: Int) {
        self.snapshot = snapshot
        self.requestLatencyMS = requestLatencyMS
        self.mediaBytesPerItem = mediaBytesPerItem
    }

    func replaceSnapshot(_ snapshot: Snapshot) {
        lock.withLock { self.snapshot = snapshot }
    }

    func resetTraffic() { lock.withLock { traffic = SyncPerformanceTraffic() } }
    func trafficSnapshot() -> SyncPerformanceTraffic { lock.withLock { traffic } }

    func response(for request: URLRequest) throws -> Data {
        try lock.withLock {
            let path = request.url?.path ?? ""
            let data = try responseData(path: path, request: request)
            traffic.requestsByPath[path, default: 0] += 1
            traffic.responseBytes += data.count
            return data
        }
    }

    private func responseData(path: String, request: URLRequest) throws -> Data {
        switch path {
        case "/api/sync/feed": return try feedResponse(request)
        case "/api/study/cards/batch": return try cardsResponse(request)
        case "/api/study/known-kanji":
            return Data(#"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8)
        case "/api/study/session/start": return snapshot.session
        case "/api/study/offline-reserve": return snapshot.reserve
        case "/api/study/media/batch": return try mediaResponse(request)
        default: throw URLError(.unsupportedURL)
        }
    }

    private func feedResponse(_ request: URLRequest) throws -> Data {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let after = Int64(query.first { $0.name == "after_checkpoint" }?.value ?? "0") ?? 0
        let limit = Int(query.first { $0.name == "per_page" }?.value ?? "50") ?? 50
        let remaining = snapshot.feedEntries.filter { $0.checkpoint > after }
        let entries = Array(remaining.prefix(limit))
        let entryData = try JSONEncoder().encode(entries)
        let next = entries.last?.checkpoint ?? after
        return Data("{\"data\":".utf8) + entryData + Data(
            ",\"meta\":{\"next_checkpoint\":\(next),\"has_more\":\(remaining.count > entries.count)}}".utf8
        )
    }

    private func cardsResponse(_ request: URLRequest) throws -> Data {
        let cards = try requestIDs(request).compactMap { snapshot.cards[$0] }
        return Self.envelope("cards", values: cards)
    }

    private func mediaResponse(_ request: URLRequest) throws -> Data {
        let ids = try requestIDs(request)
        let payload = Data(repeating: 0x5a, count: mediaBytesPerItem).base64EncodedString()
        let items = ids.map {
            ["id": $0, "mimeType": "audio/mpeg", "data": payload]
        }
        traffic.mediaItems += ids.count
        traffic.mediaBytes += ids.count * mediaBytesPerItem
        return try JSONSerialization.data(withJSONObject: ["items": items])
    }

    private func requestIDs(_ request: URLRequest) throws -> [String] {
        try JSONDecoder().decode(IDs.self, from: requestBody(request)).ids
    }

    static func envelope(_ key: String, values: [Data]) -> Data {
        var result = Data("{\"\(key)\":[".utf8)
        for (index, value) in values.enumerated() {
            if index > 0 { result.append(0x2c) }
            result.append(value)
        }
        result.append(Data("]}".utf8))
        return result
    }
}

nonisolated final class SyncPerformanceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var transports: [String: SyncPerformanceTransport] = [:]
    private let deliveryLock = NSLock()
    private var cancelled = false

    static func install(_ transport: SyncPerformanceTransport, host: String) {
        registryLock.withLock { transports[host] = transport }
    }

    static func remove(host: String) {
        _ = registryLock.withLock { transports.removeValue(forKey: host) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let transport = Self.registryLock.withLock { Self.transports[request.url?.host ?? ""] }
        guard let transport else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(transport.requestLatencyMS)
        ) { [self] in deliver(transport) }
    }

    private func deliver(_ transport: SyncPerformanceTransport) {
        deliveryLock.withLock {
            guard !cancelled else { return }
            do {
                let data = try transport.response(for: request)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() { deliveryLock.withLock { cancelled = true } }
}
