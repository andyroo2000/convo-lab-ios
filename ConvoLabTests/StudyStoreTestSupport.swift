import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    static func response(
        statusCode: Int = 200,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: URL(string: "https://learning-os.example")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            data
        )
    }

    @MainActor
    func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    func makeDeferredClient(
        handler: @escaping MockURLProtocol.DeferredHandler
    ) -> APIClient {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    func makeClient(protocolClass: AnyClass) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    func makeDelayedPitchClient(
        responseData: Data,
        gate: LockedRequestGate
    ) -> APIClient {
        DelayedPitchURLProtocol.responseData = responseData
        DelayedPitchURLProtocol.gate = gate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedPitchURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    func makeDelayedAnswerAudioClient(
        responseData: Data,
        gate: LockedRequestGate
    ) -> APIClient {
        DelayedAnswerAudioURLProtocol.responseData = responseData
        DelayedAnswerAudioURLProtocol.gate = gate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedAnswerAudioURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    func makeDelayedAnswerAudioDownloadClient(
        responseData: Data,
        gate: LockedRequestGate
    ) -> APIClient {
        DelayedAnswerAudioDownloadURLProtocol.responseData = responseData
        DelayedAnswerAudioDownloadURLProtocol.gate = gate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedAnswerAudioDownloadURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    func makeCard(
        id: String,
        syncId: String? = nil,
        expression: String,
        mediaURL: String? = nil,
        queueState: String = "review",
        dueAt: Date? = nil,
        scheduler: JSONValue? = nil,
        masteryLevel: String? = nil
    ) -> StudyCard {
        var prompt: [String: JSONValue] = ["cueText": .string(expression)]
        if let mediaURL {
            prompt["cueAudio"] = .object(["url": .string(mediaURL)])
        }
        return StudyCard(
            id: id,
            syncId: syncId,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(prompt),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: dueAt,
                introducedAt: nil,
                failedAt: nil,
                queueState: queueState,
                scheduler: scheduler,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            masteryLevel: masteryLevel,
            createdAt: .now,
            updatedAt: .now
        )
    }

    @MainActor
    func sessionResponseData(
        cards: [StudyCard],
        lessonBatchSize: Int = 5
    ) throws -> Data {
        let session = StudySession(
            overview: StudyOverview(
                dueCount: cards.filter { $0.state.queueState != "new" }.count,
                newCount: cards.filter { $0.state.queueState == "new" }.count,
                reviewCount: cards.filter { $0.state.queueState != "new" }.count,
                newCardsPerDay: 20,
                newCardsAvailableToday: cards.filter { $0.state.queueState == "new" }.count,
                lessonBatchSize: lessonBatchSize
            ),
            cards: cards
        )
        let object = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        return try JSONSerialization.data(withJSONObject: ["data": object])
    }

    @MainActor
    func cardWithResolvedPitchAccent(_ card: StudyCard) -> StudyCard {
        StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer.replacingObjectValues([
                "pitchAccent": .object([
                    "status": .string("resolved"),
                    "expression": .string("会社"),
                    "reading": .string("かいしゃ"),
                    "morae": .array([.string("か"), .string("い"), .string("しゃ")]),
                    "pattern": .array([.number(0), .number(1), .number(1)]),
                    "patternName": .string("平板"),
                ]),
            ]),
            state: card.state,
            answerAudioSource: card.answerAudioSource,
            createdAt: card.createdAt,
            updatedAt: .now
        )
    }

    @MainActor
    func persistedCard(
        in container: ModelContainer
    ) throws -> StudyCard {
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        return try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
    }

    @MainActor
    func waitUntil(
        _ condition: @escaping @Sendable () -> Bool
    ) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor
    func makeQueueItem(id: String, position: Int) -> StudyNewCardQueueItem {
        StudyNewCardQueueItem(
            id: id,
            noteId: id,
            cardType: "recognition",
            displayText: id,
            meaning: "meaning",
            queuePosition: position,
            createdAt: .now,
            updatedAt: .now
        )
    }

    @MainActor
    func queuePage(
        items: [StudyNewCardQueueItem],
        total: Int,
        nextCursor: String?
    ) throws -> Data {
        try StorageCodec.encoder.encode(
            StudyNewCardQueueResponse(
                items: items,
                total: total,
                limit: 100,
                nextCursor: nextCursor
            )
        )
    }

    @MainActor
    func makeStore(protocolClass: AnyClass) throws -> StudyStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        let container = try Persistence.makeContainer(inMemory: true)
        return StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

final class LockedRequestPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }
}

final class LockedRequestBodies: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var values: [Data] {
        lock.withLock { storage }
    }

    func append(_ body: Data) {
        lock.withLock { storage.append(body) }
    }
}

final class OverlappingStudySessionURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var firstReviewData = Data()
    nonisolated(unsafe) private static var secondReviewData = Data()
    nonisolated(unsafe) private static var lessonData = Data()
    nonisolated(unsafe) private static var pendingFirstReview: OverlappingStudySessionURLProtocol?
    nonisolated(unsafe) private static var pendingLesson: OverlappingStudySessionURLProtocol?
    nonisolated(unsafe) private static var reviewRequestCount = 0
    nonisolated(unsafe) private static var holdsLesson = false

    static var hasPendingFirstReview: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingFirstReview != nil
    }

    static var hasPendingLesson: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingLesson != nil
    }

    static func configure(
        firstReview: Data,
        secondReview: Data,
        lesson: Data,
        holdLesson: Bool = false
    ) {
        lock.lock()
        firstReviewData = firstReview
        secondReviewData = secondReview
        lessonData = lesson
        pendingFirstReview = nil
        pendingLesson = nil
        reviewRequestCount = 0
        holdsLesson = holdLesson
        lock.unlock()
    }

    static func releaseFirstReview() {
        lock.lock()
        let request = pendingFirstReview
        let data = firstReviewData
        pendingFirstReview = nil
        lock.unlock()
        request?.respond(with: data)
    }

    static func releaseLesson() {
        lock.lock()
        let request = pendingLesson
        let data = lessonData
        pendingLesson = nil
        lock.unlock()
        request?.respond(with: data)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        if request.url?.path == "/api/study/lessons/start" {
            if Self.holdsLesson {
                Self.pendingLesson = self
                Self.lock.unlock()
                return
            }
            let data = Self.lessonData
            Self.lock.unlock()
            respond(with: data)
            return
        }
        Self.reviewRequestCount += 1
        if Self.reviewRequestCount == 1 {
            Self.pendingFirstReview = self
            Self.lock.unlock()
            return
        }
        let data = Self.secondReviewData
        Self.lock.unlock()
        respond(with: data)
    }

    override func stopLoading() {}

    private func respond(with data: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class OutOfOrderCardListURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var firstResponseData = Data()
    nonisolated(unsafe) private static var secondResponseData = Data()
    nonisolated(unsafe) private static var pendingFirstRequest: OutOfOrderCardListURLProtocol?

    static var hasPendingFirstRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingFirstRequest != nil
    }

    static func configure(first: Data, second: Data) {
        lock.lock()
        firstResponseData = first
        secondResponseData = second
        pendingFirstRequest = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.query?.contains("q=first") == true {
            Self.lock.lock()
            Self.pendingFirstRequest = self
            Self.lock.unlock()
            return
        }

        respond(with: Self.secondResponseData)
        Self.lock.lock()
        let firstRequest = Self.pendingFirstRequest
        Self.pendingFirstRequest = nil
        Self.lock.unlock()
        firstRequest?.respond(with: Self.firstResponseData)
    }

    override func stopLoading() {}

    private func respond(with data: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class OverlappingCardListPageURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var initialPage = Data()
    nonisolated(unsafe) private static var refreshedPage = Data()
    nonisolated(unsafe) private static var staleNextPage = Data()
    nonisolated(unsafe) private static var servedInitialPage = false
    nonisolated(unsafe) private static var pendingNextPage: OverlappingCardListPageURLProtocol?

    static var hasPendingNextPage: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingNextPage != nil
    }

    static func configure(initialPage: Data, refreshedPage: Data, staleNextPage: Data) {
        lock.lock()
        self.initialPage = initialPage
        self.refreshedPage = refreshedPage
        self.staleNextPage = staleNextPage
        servedInitialPage = false
        pendingNextPage = nil
        lock.unlock()
    }

    static func releasePendingNextPage() {
        lock.lock()
        let request = pendingNextPage
        pendingNextPage = nil
        let data = staleNextPage
        lock.unlock()
        request?.respond(with: data)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.query?.contains("cursor=") == true {
            Self.lock.lock()
            Self.pendingNextPage = self
            Self.lock.unlock()
            return
        }

        Self.lock.lock()
        let data = Self.servedInitialPage ? Self.refreshedPage : Self.initialPage
        Self.servedInitialPage = true
        Self.lock.unlock()
        respond(with: data)
    }

    override func stopLoading() {}

    private func respond(with data: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class OverlappingQueueReorderURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var initialPage = Data()
    nonisolated(unsafe) private static var refreshedPage = Data()
    nonisolated(unsafe) private static var reorderPage = Data()
    nonisolated(unsafe) private static var reorderStatus = 200
    nonisolated(unsafe) private static var nextPage = Data()
    nonisolated(unsafe) private static var nextPageStatus = 200
    nonisolated(unsafe) private static var servedInitialPage = false
    nonisolated(unsafe) private static var holdSecondRefresh = false
    nonisolated(unsafe) private static var pendingRefresh: OverlappingQueueReorderURLProtocol?
    nonisolated(unsafe) private static var pendingLoadMore: OverlappingQueueReorderURLProtocol?
    nonisolated(unsafe) private static var pendingReorder: OverlappingQueueReorderURLProtocol?

    static var hasPendingRefresh: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingRefresh != nil
    }

    static var hasPendingReorder: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingReorder != nil
    }

    static var hasPendingLoadMore: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingLoadMore != nil
    }

    static func configure(
        initialPage: Data,
        refreshedPage: Data,
        reorderPage: Data,
        reorderStatus: Int,
        holdSecondRefresh: Bool = false,
        nextPage: Data = Data(),
        nextPageStatus: Int = 200
    ) {
        lock.lock()
        self.initialPage = initialPage
        self.refreshedPage = refreshedPage
        self.reorderPage = reorderPage
        self.reorderStatus = reorderStatus
        self.holdSecondRefresh = holdSecondRefresh
        self.nextPage = nextPage
        self.nextPageStatus = nextPageStatus
        servedInitialPage = false
        pendingRefresh = nil
        pendingLoadMore = nil
        pendingReorder = nil
        lock.unlock()
    }

    static func releasePendingRefresh() {
        lock.lock()
        let request = pendingRefresh
        pendingRefresh = nil
        let data = refreshedPage
        lock.unlock()
        request?.respond(with: data, statusCode: 200)
    }

    static func releasePendingReorder() {
        lock.lock()
        let request = pendingReorder
        pendingReorder = nil
        let data = reorderPage
        let status = reorderStatus
        lock.unlock()
        request?.respond(with: data, statusCode: status)
    }

    static func releasePendingLoadMore() {
        lock.lock()
        let request = pendingLoadMore
        pendingLoadMore = nil
        let data = nextPage
        let status = nextPageStatus
        lock.unlock()
        request?.respond(with: data, statusCode: status)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.path == "/api/study/new-queue/reorder" {
            Self.lock.lock()
            Self.pendingReorder = self
            Self.lock.unlock()
            return
        }

        if request.url?.query?.contains("cursor=") == true {
            Self.lock.lock()
            Self.pendingLoadMore = self
            Self.lock.unlock()
            return
        }

        Self.lock.lock()
        if Self.servedInitialPage, Self.holdSecondRefresh {
            Self.pendingRefresh = self
            Self.lock.unlock()
            return
        }
        let data = Self.servedInitialPage ? Self.refreshedPage : Self.initialPage
        Self.servedInitialPage = true
        Self.lock.unlock()
        respond(with: data, statusCode: 200)
    }

    override func stopLoading() {}

    private func respond(with data: Data, statusCode: Int) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class LockedRequestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    var hasStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    func markStarted() {
        condition.lock()
        started = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForRelease() {
        condition.lock()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

final class LockedDeferredResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: MockURLProtocol.DeferredCompletion?
    private var pendingWaiters: [CheckedContinuation<Void, Never>] = []

    var hasPendingResponse: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completion != nil
    }

    func hold(_ completion: @escaping MockURLProtocol.DeferredCompletion) {
        lock.lock()
        self.completion = completion
        let pendingWaiters = pendingWaiters
        self.pendingWaiters = []
        lock.unlock()
        pendingWaiters.forEach { $0.resume() }
    }

    func waitUntilPending() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if completion != nil {
                lock.unlock()
                continuation.resume()
            } else {
                pendingWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func succeed(with response: (HTTPURLResponse, Data)) {
        lock.lock()
        let completion = completion
        self.completion = nil
        lock.unlock()
        completion?(.success(response))
    }
}

final class DelayedPitchURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var gate: LockedRequestGate?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard request.url?.path.hasSuffix("/pitch-accent") == true else {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let responseData = Self.responseData
        let gate = Self.gate
        gate?.markStarted()
        DispatchQueue.global().async { [self] in
            gate?.waitForRelease()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class DelayedAnswerAudioURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var gate: LockedRequestGate?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard request.url?.path.hasSuffix("/regenerate-answer-audio") == true else {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("regenerated-audio".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let responseData = Self.responseData
        let gate = Self.gate
        gate?.markStarted()
        DispatchQueue.global().async { [self] in
            gate?.waitForRelease()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class DelayedAnswerAudioDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var gate: LockedRequestGate?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if request.url?.path.hasSuffix("/regenerate-answer-audio") == true {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.responseData)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let gate = Self.gate
        gate?.markStarted()
        DispatchQueue.global().async { [self] in
            gate?.waitForRelease()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("regenerated-audio".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
