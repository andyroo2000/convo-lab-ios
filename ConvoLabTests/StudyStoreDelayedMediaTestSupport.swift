import Foundation
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func makeDelayedPitchClient(
        responseData: Data,
        gate: LockedRequestGate
    ) -> APIClient {
        DelayedPitchURLProtocol.responseData = responseData
        DelayedPitchURLProtocol.gate = gate
        return makeClient(protocolClass: DelayedPitchURLProtocol.self)
    }

    @MainActor
    func makeDelayedAnswerAudioClient(
        responseData: Data,
        gate: LockedRequestGate
    ) -> APIClient {
        DelayedAnswerAudioURLProtocol.responseData = responseData
        DelayedAnswerAudioURLProtocol.gate = gate
        return makeClient(protocolClass: DelayedAnswerAudioURLProtocol.self)
    }

    @MainActor
    func makeDelayedAnswerAudioDownloadClient(
        responseData: Data,
        gate: LockedRequestGate
    ) -> APIClient {
        DelayedAnswerAudioDownloadURLProtocol.responseData = responseData
        DelayedAnswerAudioDownloadURLProtocol.gate = gate
        return makeClient(protocolClass: DelayedAnswerAudioDownloadURLProtocol.self)
    }
}

final class DelayedPitchURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var gate: LockedRequestGate?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard request.url?.path.hasSuffix("/pitch-accent") == true else {
            deliver(nil, statusCode: 204, contentType: nil)
            return
        }
        deliverAfterRelease(Self.responseData, gate: Self.gate)
    }

    override func stopLoading() {}
}

final class DelayedAnswerAudioURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var gate: LockedRequestGate?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard request.url?.path.hasSuffix("/regenerate-answer-audio") == true else {
            deliver(Data("regenerated-audio".utf8), contentType: "audio/mpeg")
            return
        }

        deliverAfterRelease(Self.responseData, gate: Self.gate)
    }

    override func stopLoading() {}
}

final class DelayedAnswerAudioDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var gate: LockedRequestGate?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.path.hasSuffix("/regenerate-answer-audio") == true {
            deliver(Self.responseData)
            return
        }

        deliverAfterRelease(
            Data("regenerated-audio".utf8),
            gate: Self.gate,
            contentType: "audio/mpeg"
        )
    }

    override func stopLoading() {}
}
