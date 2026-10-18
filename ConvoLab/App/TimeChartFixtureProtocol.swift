#if DEBUG
import Foundation

nonisolated final class TimeChartFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestCounts: [String: Int] = [:]
    nonisolated(unsafe) private static var responseBytes = 0
    nonisolated(unsafe) private static var delayedAnchor: String?
    private var work: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { work?.cancel() }

    static func traffic() -> [String: Int] {
        lock.withLock { requestCounts.merging(["responseBytes": responseBytes]) { _, new in new } }
    }

    static func delay(anchor: String) {
        lock.withLock { delayedAnchor = anchor }
    }

    override func startLoading() {
        let work = DispatchWorkItem { [weak self] in self?.respond() }
        self.work = work
        let value = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "anchorDate" }?.value
        let isDelayed = Self.lock.withLock { value != nil && value == Self.delayedAnchor }
        let latency = isDelayed ? 8_000 : 40
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(latency), execute: work)
    }

    private func respond() {
        guard let url = request.url else { return }
        guard url.path == "/api/study/activity-analytics" else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let history = TimeChartFixtureHistory.shared
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "anchorDate" }?.value ?? history.anchor(history.now)
        let formatter = DateFormatter()
        formatter.calendar = history.calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = history.calendar.timeZone
        guard let date = formatter.date(from: value) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(history.response(anchor: date)) else { return }
        Self.lock.withLock {
            Self.requestCounts[value, default: 0] += 1
            Self.responseBytes += data.count
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
