import Foundation

/// Serves deterministic HTTP payloads while retaining the real API decoder and disk store.
nonisolated final class StudyTimeStartupTransport: @unchecked Sendable {
    struct Reply {
        let identifier: Int
        let delayMS: Int
        let data: Data
    }

    private let lock = NSLock()
    private let started = ContinuousClock.now
    private var traffic = StudyTimeStartupTraffic()
    private let history: Data
    private let analyticsByScope: [String: Data]
    let delaysMS: [String: Int]

    init(history: Data, analyticsByScope: [String: Data], large: Bool) {
        self.history = history
        self.analyticsByScope = analyticsByScope
        delaysMS = ["upload": large ? 150 : 15, "history": large ? 1_200 : 120,
                    "analytics": large ? 200 : 20]
    }

    func begin(_ request: URLRequest) throws -> Reply {
        try lock.withLock {
            let body = request.httpMethod == "POST" ? try requestBody(request) : Data()
            let payload = try payload(request, body: body)
            let identifier = traffic.requests.count
            traffic.requests.append(.init(path: request.url!.path, query: request.url!.query ?? "",
                                          startedMS: elapsed(), requestBytes: body.count))
            traffic.inFlight += 1
            traffic.peakInFlight = max(traffic.peakInFlight, traffic.inFlight)
            return .init(identifier: identifier, delayMS: delaysMS[payload.route]!, data: payload.data)
        }
    }

    func finish(_ reply: Reply, cancelled: Bool) {
        lock.withLock {
            guard traffic.requests[reply.identifier].endedMS == nil else { return }
            traffic.requests[reply.identifier].endedMS = elapsed()
            traffic.requests[reply.identifier].cancelled = cancelled
            traffic.requests[reply.identifier].responseBytes = cancelled ? 0 : reply.data.count
            traffic.inFlight -= 1
        }
    }

    func snapshot() -> StudyTimeStartupTraffic { lock.withLock { traffic } }

    private func payload(_ request: URLRequest, body: Data) throws -> (route: String, data: Data) {
        switch (request.httpMethod, request.url?.path) {
        case ("POST", "/api/study/activity-sessions/batch"):
            let value = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            guard var sessions = value?["sessions"] as? [[String: Any]] else { throw URLError(.badServerResponse) }
            for index in sessions.indices { sessions[index]["id"] = "uploaded-\(index)" }
            traffic.uploadedSessions += sessions.count
            return ("upload", try JSONSerialization.data(withJSONObject: sessions))
        case ("GET", "/api/study/activity-sessions"):
            return ("history", history)
        case ("GET", "/api/study/activity-analytics"):
            let ranges = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .filter { $0.name == "ranges[]" }.compactMap(\.value).sorted().joined(separator: ",") ?? ""
            guard let data = analyticsByScope[ranges] else { throw URLError(.badURL) }
            return ("analytics", data)
        default: throw URLError(.unsupportedURL)
        }
    }

    private func elapsed() -> Double { StudyTimeStartupProbe.ms(started.duration(to: .now)) }
}
