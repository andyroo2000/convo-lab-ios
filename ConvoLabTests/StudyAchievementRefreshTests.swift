import XCTest
@testable import ConvoLab

extension StudyAchievementTests {
    @MainActor
    func testStoreLoadsCatalogAndAuthenticatedProgressFromCanonicalEndpoints() async throws {
        let catalogPayload = try JSONEncoder().encode(makeCatalog())
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = { request in
            let path = request.url?.path
            let body: Data
            switch path {
            case "/api/achievements/catalog": body = catalogPayload
            case "/api/achievements/evaluate":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer achievement-token")
                body = Data(
                    #"{"revision":"achievement-collection-v2","metricValues":{"stable.count":0,"reviews.count":120,"voice.hours":20},"awards":[{"id":"reviews.first","earnedAt":"2026-01-01T00:00:00.000Z"},{"id":"reviews.second","earnedAt":"2026-02-01T00:00:00.000Z"}]}"#
                        .utf8)
            default:
                XCTFail("Unexpected achievement request: \(path ?? "nil")")
                body = Data()
            }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!, body
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!, session: URLSession(configuration: configuration))
        Self.retainedClients.append(client)
        client.setAccessToken("achievement-token")
        let store = StudyAchievementStore(api: client)
        store.activate(userID: 41)

        await store.refresh()

        XCTAssertEqual(store.catalog?.revision, "achievement-collection-v2")
        XCTAssertEqual(store.progress?.metricValues["reviews.count"], 120)
        XCTAssertEqual(store.earnedAchievements.map(\.id), ["reviews.second", "reviews.first"])
    }

    @MainActor
    func testReadOnlyRefreshDoesNotSatisfyAuthoritativeEvaluationFreshness() async throws {
        let catalogPayload = try JSONEncoder().encode(makeCatalog())
        let progressPayload = progressPayload(reviews: 25)
        let requestMethods = LockedRequestPaths()
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            requestMethods.append("\(request.httpMethod ?? "") \(path)")
            let body =
                switch path {
                case "/api/achievements/catalog": catalogPayload
                case "/api/achievements/progress", "/api/achievements/evaluate": progressPayload
                default: Data()
                }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: body.isEmpty ? 404 : 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!, body
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!, session: URLSession(configuration: configuration))
        Self.retainedClients.append(client)
        let store = StudyAchievementStore(api: client)
        store.activate(userID: 41)

        await store.refresh(evaluate: false)
        await store.refreshIfNeeded(maxAge: 60, evaluate: true)

        XCTAssertEqual(
            requestMethods.values,
            ["GET /api/achievements/catalog", "GET /api/achievements/progress", "POST /api/achievements/evaluate"])
        XCTAssertEqual(store.progress?.metricValues["reviews.count"], 25)
    }

    @MainActor
    func testReadOnlyRefreshCanUpdateBaselineWithoutDiscardingRecordedReviews() async throws {
        let catalogPayload = try JSONEncoder().encode(makeCatalog())
        let historicalAward = award(id: "stable.first", date: "2026-08-01T12:00:00.000Z")
        let newAward = award(id: "reviews.first", date: "2026-08-28T12:01:00.000Z")
        let progressPayloads = LockedRequestBodies()
        progressPayloads.append(try achievementProgressPayload(awards: [historicalAward]))
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = { request in
            let body =
                switch request.url?.path {
                case "/api/achievements/catalog": catalogPayload
                case "/api/achievements/progress", "/api/achievements/evaluate": progressPayloads.values.last ?? Data()
                default: Data()
                }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: body.isEmpty ? 404 : 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!, body
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!, session: URLSession(configuration: configuration))
        Self.retainedClients.append(client)
        let store = StudyAchievementStore(api: client)
        store.activate(userID: 41)
        store.beginReviewSession()
        store.recordReview(makeReviewRecord(id: "review-1"))
        let localCompletion = try XCTUnwrap(store.prepareCurrentSessionCompletion())
        XCTAssertEqual(localCompletion.records.map(\.id), ["review-1"])
        XCTAssertTrue(localCompletion.newAwardIDs.isEmpty)

        await store.refresh(evaluate: false)
        store.refreshCurrentSessionBaseline()
        progressPayloads.append(try achievementProgressPayload(awards: [historicalAward, newAward]))
        await store.refresh()

        let completion = try XCTUnwrap(store.prepareCurrentSessionCompletion())
        XCTAssertEqual(completion.records.map(\.id), ["review-1"])
        XCTAssertEqual(completion.newAwardIDs, ["reviews.first"])
    }

    @MainActor
    func testReadyCompletionBaselineCannotBeRewrittenByALateRead() async throws {
        let client = makeClient()
        try installAchievementResponses(awards: [])
        let store = StudyAchievementStore(api: client)
        store.activate(userID: 41)
        await store.refresh()
        store.beginReviewSession()
        store.recordReview(makeReviewRecord(id: "review-1"))

        try installAchievementResponses(awards: [award(id: "reviews.first", date: "2026-08-28T12:01:00.000Z")])
        await store.refresh()
        XCTAssertEqual(store.prepareCurrentSessionCompletion()?.newAwardIDs, ["reviews.first"])

        store.refreshCurrentSessionBaseline()

        XCTAssertEqual(store.prepareCurrentSessionCompletion()?.newAwardIDs, ["reviews.first"])
    }

    @MainActor
    func testStoreRestoresSnapshotImmediatelyAndReusesFreshCatalog() async throws {
        let defaults = try makeDefaults()
        let catalogPayload = try JSONEncoder().encode(makeCatalog())
        let progressPayload = progressPayload(reviews: 120)
        let requestPaths = LockedRequestPaths()
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            requestPaths.append(path)
            let body =
                switch path {
                case "/api/achievements/catalog": catalogPayload
                case "/api/achievements/evaluate": progressPayload
                default: Data()
                }
            if body.isEmpty { XCTFail("Unexpected achievement request: \(path)") }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: body.isEmpty ? 404 : 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!, body
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!, session: URLSession(configuration: configuration))
        Self.retainedClients.append(client)
        let firstStore = StudyAchievementStore(api: client, defaults: defaults)
        firstStore.activate(userID: 41)
        await firstStore.refresh()

        let relaunchedStore = StudyAchievementStore(api: client, defaults: defaults)
        relaunchedStore.activate(userID: 41)

        XCTAssertEqual(relaunchedStore.catalog?.revision, "achievement-collection-v2")
        XCTAssertEqual(relaunchedStore.progress?.metricValues["reviews.count"], 120)
        XCTAssertFalse(relaunchedStore.isLoading)

        await relaunchedStore.refresh()

        XCTAssertEqual(
            requestPaths.values,
            ["/api/achievements/catalog", "/api/achievements/evaluate", "/api/achievements/evaluate"])
    }
}
