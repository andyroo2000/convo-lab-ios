#if DEBUG
import Foundation

nonisolated final class UITestPileToggleProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [String: UITestPileToggleProtocol] = [:]
    nonisolated(unsafe) private static var permits: [String: Int] = [:]
    nonisolated(unsafe) private static var active = true

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private var kind: String {
        if request.httpMethod == "PUT" { return "save" }
        return request.url?.path == "/api/study/piles" ? "counts" : "overview"
    }

    override func startLoading() {
        if kind == "overview" { deliver(status: 503); return }
        let status = Self.lock.withLock { () -> Int? in
            if let status = Self.permits.removeValue(forKey: kind) { return status }
            Self.pending[kind] = self
            return nil
        }
        if let status { deliver(status: status) }
    }

    static func complete(_ kind: String, status: Int = 200) {
        let request = lock.withLock { () -> UITestPileToggleProtocol? in
            if let request = pending.removeValue(forKey: kind) { return request }
            permits[kind] = status
            return nil
        }
        request?.deliver(status: status)
    }

    private func deliver(status: Int) {
        if kind == "save", status == 200 { Self.lock.withLock { Self.active = false } }
        let data = status == 200 ? Self.catalogData : Data(#"{"message":"Save rejected for test"}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    static var catalogData: Data {
        let active = lock.withLock { Self.active }
        return Data(#"{"piles":[{"id":"01jzq4nny5xbnzw14q1g68b2yt","title":"Quartet 1","position":1,"is_active":true,"source_reference":null,"new_count":20,"ready_count":3,"introduced_count":4,"chapters":[{"id":"01jzq4nny5xbnzw14q1g68b2yv","title":"Chapter 1","position":1,"is_active":\#(active),"source_reference":null,"new_count":20,"ready_count":3,"introduced_count":4}]}],"uncategorized":{"new_count":0,"ready_count":0,"introduced_count":0},"learn_soon":{"new_count":0,"ready_count":0,"introduced_count":0},"next_cursor":null}"#.utf8)
    }
}
#endif
