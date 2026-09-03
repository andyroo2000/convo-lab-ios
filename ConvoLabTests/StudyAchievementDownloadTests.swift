import XCTest
@testable import ConvoLab

extension StudyAchievementTests {
    @MainActor
    func testStoreDownloadsEveryLockedAndEarnedBadgeBeforeItIsEarned() async throws {
        let catalog = makeCatalog()
        let catalogPayload = try JSONEncoder().encode(catalog)
        let progressPayload = progressPayload(reviews: 0)
        let requestPaths = LockedRequestPaths()
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            requestPaths.append(path)
            let body: Data
            let contentType: String
            switch path {
            case "/api/achievements/catalog":
                body = catalogPayload
                contentType = "application/json"
            case "/api/achievements/evaluate":
                body = progressPayload
                contentType = "application/json"
            case _ where path.hasPrefix("/achievement-assets/"):
                body = Data("png-\(path)".utf8)
                contentType = "image/png"
            default:
                XCTFail("Unexpected achievement request: \(path)")
                body = Data()
                contentType = "application/json"
            }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: body.isEmpty ? 404 : 200, httpVersion: nil,
                    headerFields: ["Content-Type": contentType])!, body
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!, session: URLSession(configuration: configuration))
        Self.retainedClients.append(client)
        let container = try Persistence.makeContainer(inMemory: true)
        let mediaCache = MediaCache(initialUserID: 41, api: client, context: container.mainContext)
        let store = StudyAchievementStore(api: client, mediaCache: mediaCache)
        store.activate(userID: 41)

        await store.refresh()
        await store.waitForAssetPreparation()

        let expectedPaths = Set(catalog.offlineImageAssets.map(\.path))
        let downloadedPaths = Set(requestPaths.values.filter { $0.hasPrefix("/achievement-assets/") })
        XCTAssertEqual(downloadedPaths, expectedPaths)
        XCTAssertEqual(store.cachedAssetURLs.count, expectedPaths.count)
        XCTAssertTrue(store.preparingAssetPaths.isEmpty)

        for asset in catalog.offlineImageAssets {
            let remoteURL = try XCTUnwrap(client.sameOriginResourceURL(asset.path))
            XCTAssertNotNil(mediaCache.localURL(for: remoteURL))
        }

        try mediaCache.clearDownloadedMedia()
        store.downloadedMediaWasCleared()
        await store.waitForAssetPreparation()

        let redownloadedPaths = requestPaths.values.filter { $0.hasPrefix("/achievement-assets/") }
        XCTAssertEqual(redownloadedPaths.count, expectedPaths.count * 2)
        XCTAssertEqual(store.cachedAssetURLs.count, expectedPaths.count)
        for asset in catalog.offlineImageAssets {
            let remoteURL = try XCTUnwrap(client.sameOriginResourceURL(asset.path))
            XCTAssertNotNil(mediaCache.localURL(for: remoteURL))
        }
    }

    @MainActor
    func testStoreFinishesRefreshWhileBadgeDownloadsContinue() async throws {
        let catalogPayload = try JSONEncoder().encode(makeCatalog())
        let (requests, requestContinuation) = AsyncStream<(URLRequest, MockURLProtocol.DeferredCompletion)>.makeStream()
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = { request, completion in requestContinuation.yield((request, completion)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!, session: URLSession(configuration: configuration))
        Self.retainedClients.append(client)
        let container = try Persistence.makeContainer(inMemory: true)
        let store = StudyAchievementStore(
            api: client, mediaCache: MediaCache(initialUserID: 41, api: client, context: container.mainContext))
        store.activate(userID: 41)
        var iterator = requests.makeAsyncIterator()
        let refreshFinished = expectation(description: "Achievement refresh finished")
        let refreshTask = Task {
            await store.refresh()
            refreshFinished.fulfill()
        }

        guard let (catalogRequest, catalogCompletion) = await iterator.next() else {
            return XCTFail("Expected the catalog request")
        }
        catalogCompletion(.success(response(for: catalogRequest, data: catalogPayload)))
        guard let (progressRequest, progressCompletion) = await iterator.next() else {
            return XCTFail("Expected the progress request")
        }
        progressCompletion(.success(response(for: progressRequest, data: progressPayload(reviews: 0))))
        guard let (assetRequest, assetCompletion) = await iterator.next() else {
            return XCTFail("Expected a badge asset request")
        }
        XCTAssertTrue(assetRequest.url?.path.hasPrefix("/achievement-assets/") == true)

        await fulfillment(of: [refreshFinished], timeout: 1)
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.preparingAssetPaths.isEmpty)

        store.deactivate()
        assetCompletion(.failure(CancellationError()))
        await refreshTask.value
    }

    @MainActor
    func testStoreSurfacesInitialProgressFailureInsteadOfShowingEmptyHistory() async throws {
        let catalogPayload = try JSONEncoder().encode(makeCatalog())
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/achievements/catalog" {
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!, catalogPayload
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 503, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!, Data(#"{"message":"Unavailable"}"#.utf8)
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

        XCTAssertNotNil(store.catalog)
        XCTAssertNil(store.progress)
        XCTAssertEqual(store.progressErrorMessage, "Your badges couldn’t be refreshed right now.")
        XCTAssertTrue(store.earnedAchievements.isEmpty)
        XCTAssertEqual(store.inProgressAchievements.map(\.id), ["reviews.first", "voice.first", "stable.first"])
    }

    @MainActor
    func testAccountSwitchDropsStaleRefreshAndForcedRefreshWaitsForInFlightLoad() async throws {
        let catalogPayload = try JSONEncoder().encode(makeCatalog())
        let (requests, requestContinuation) = AsyncStream<(URLRequest, MockURLProtocol.DeferredCompletion)>.makeStream()
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = { request, completion in requestContinuation.yield((request, completion)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!, session: URLSession(configuration: configuration))
        Self.retainedClients.append(client)
        let store = StudyAchievementStore(api: client)
        var iterator = requests.makeAsyncIterator()

        store.activate(userID: 1)
        let staleRefresh = Task { await store.refresh() }
        guard let (staleCatalogRequest, staleCatalogCompletion) = await iterator.next() else {
            return XCTFail("Expected the stale catalog request")
        }
        XCTAssertEqual(staleCatalogRequest.url?.path, "/api/achievements/catalog")
        store.activate(userID: 2)
        staleCatalogCompletion(.success(response(for: staleCatalogRequest, data: catalogPayload)))
        await staleRefresh.value
        XCTAssertNil(store.catalog)
        XCTAssertNil(store.progress)

        let initialRefresh = Task { await store.refresh() }
        guard let (initialCatalogRequest, initialCatalogCompletion) = await iterator.next() else {
            return XCTFail("Expected the current catalog request")
        }
        let forcedRefresh = Task { await store.refresh() }
        initialCatalogCompletion(.success(response(for: initialCatalogRequest, data: catalogPayload)))
        guard let (initialProgressRequest, initialProgressCompletion) = await iterator.next() else {
            return XCTFail("Expected the current progress request")
        }
        initialProgressCompletion(.success(response(for: initialProgressRequest, data: progressPayload(reviews: 25))))
        await initialRefresh.value

        guard let (forcedProgressRequest, forcedProgressCompletion) = await iterator.next() else {
            return XCTFail("Expected the forced progress request")
        }
        XCTAssertEqual(forcedProgressRequest.url?.path, "/api/achievements/evaluate")
        forcedProgressCompletion(.success(response(for: forcedProgressRequest, data: progressPayload(reviews: 50))))
        await forcedRefresh.value

        XCTAssertEqual(store.progress?.metricValues["reviews.count"], 50)
    }
}
