import Foundation

nonisolated final class StudyTimeStartupURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var transports: [String: StudyTimeStartupTransport] = [:]
    private let deliveryLock = NSLock()
    private var pending: (StudyTimeStartupTransport, StudyTimeStartupTransport.Reply)?
    private var stopped = false

    static func install(_ transport: StudyTimeStartupTransport, host: String) {
        registryLock.withLock { transports[host] = transport }
    }

    static func remove(host: String) {
        _ = registryLock.withLock { transports.removeValue(forKey: host) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        deliveryLock.withLock {
            guard !stopped else { return }
            do {
                guard let transport = Self.registryLock.withLock({ Self.transports[request.url?.host ?? ""] })
                else { throw URLError(.unsupportedURL) }
                let reply = try transport.begin(request)
                pending = (transport, reply)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(reply.delayMS)) {
                    self.deliver()
                }
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    private func deliver() {
        deliveryLock.withLock {
            guard !stopped, let (transport, reply) = pending else { return }
            pending = nil
            transport.finish(reply, cancelled: false)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        deliveryLock.withLock {
            stopped = true
            if let (transport, reply) = pending { transport.finish(reply, cancelled: true) }
            pending = nil
        }
    }
}
