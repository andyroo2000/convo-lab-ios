import XCTest
@testable import ConvoLab

final class StudyAchievementTests: XCTestCase {
    private nonisolated(unsafe) static var retainedClients: [APIClient] = []

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    func testNoDataUsesCanonicalFallbackOrder() throws {
        let catalog = try makeCatalog().validated()

        let featured = StudyAchievementPresentationModel.closestInProgress(
            catalog: catalog,
            progress: nil
        )

        XCTAssertEqual(
            featured.map(\.id),
            ["reviews.first", "voice.first", "stable.first"]
        )
        XCTAssertTrue(featured.allSatisfy { !$0.isEarned && $0.currentValue == nil })
    }

    func testNewAccountUsesCanonicalFallbackOrderBeforeProgressStarts() throws {
        let catalog = try makeCatalog().validated()
        let progress = StudyAchievementProgress(
            revision: catalog.revision,
            metricValues: ["stable.count": 0, "reviews.count": 0, "voice.hours": 0],
            awards: []
        )

        XCTAssertEqual(
            StudyAchievementPresentationModel.closestInProgress(
                catalog: catalog,
                progress: progress
            ).map(\.id),
            ["reviews.first", "voice.first", "stable.first"]
        )
    }

    func testInProgressShowsOnlyTheNextLockedTierPerFamily() throws {
        let catalog = try makeCatalog().validated()
        let progress = StudyAchievementProgress(
            revision: catalog.revision,
            metricValues: [
                "stable.count": 0,
                "reviews.count": 120,
                "voice.hours": 20,
            ],
            awards: [
                award(id: "reviews.first", date: "2026-01-01T00:00:00.000Z"),
                award(id: "reviews.second", date: "2026-02-01T00:00:00.000Z"),
            ]
        )

        let featured = StudyAchievementPresentationModel.closestInProgress(
            catalog: catalog,
            progress: progress
        )

        XCTAssertEqual(featured.map(\.id), ["voice.first", "stable.first"])
        XCTAssertTrue(featured.allSatisfy { !$0.isEarned })
    }

    func testHiddenFamilyStaysOutOfInProgressButAppearsAfterItIsEarned() throws {
        var catalog = makeCatalog()
        let family = catalog.families[0]
        var families = catalog.families
        families[0] = StudyAchievementFamily(
            key: family.key,
            title: family.title,
            metricKey: family.metricKey,
            unit: family.unit,
            hiddenUntilEarned: true,
            tiers: family.tiers
        )
        catalog = try StudyAchievementCatalog(
            revision: catalog.revision,
            presentation: catalog.presentation,
            families: families
        ).validated()

        let noProgress = StudyAchievementPresentationModel.closestInProgress(
            catalog: catalog,
            progress: nil
        )
        XCTAssertFalse(noProgress.map(\.id).contains("stable.first"))

        let inProgress = StudyAchievementPresentationModel.closestInProgress(
            catalog: catalog,
            progress: StudyAchievementProgress(
                revision: catalog.revision,
                metricValues: ["stable.count": 24, "reviews.count": 1, "voice.hours": 1],
                awards: []
            )
        )
        XCTAssertFalse(inProgress.map(\.id).contains("stable.first"))

        let earned = StudyAchievementPresentationModel.recentEarned(
            catalog: catalog,
            progress: StudyAchievementProgress(
                revision: catalog.revision,
                metricValues: ["stable.count": 25],
                awards: [award(id: "stable.first", date: "2026-01-01T00:00:00.000Z")]
            )
        )
        XCTAssertTrue(earned.map(\.id).contains("stable.first"))
    }

    func testEarnedHistoryIncludesEveryAwardNewestFirst() throws {
        let catalog = try makeCatalog().validated()
        let earned = StudyAchievementPresentationModel.recentEarned(
            catalog: catalog,
            progress: StudyAchievementProgress(
                revision: catalog.revision,
                metricValues: [
                    "stable.count": 100,
                    "reviews.count": 120,
                    "voice.hours": 100,
                ],
                awards: [
                    award(id: "stable.first", date: "2026-01-01T00:00:00.000Z"),
                    award(id: "reviews.second", date: "2026-03-01T00:00:00.000Z"),
                    award(id: "voice.first", date: "2026-02-01T00:00:00.000Z"),
                ]
            ),
            count: .max
        )

        XCTAssertEqual(earned.map(\.id), ["reviews.second", "voice.first", "stable.first"])
    }

    func testRevisionMismatchFallsBackInsteadOfApplyingStaleMetrics() throws {
        let catalog = try makeCatalog().validated()
        let progress = StudyAchievementProgress(
            revision: "future-revision",
            metricValues: ["reviews.count": 10_000],
            awards: [award(id: "reviews.second", date: "2026-01-01T00:00:00.000Z")]
        )

        XCTAssertEqual(
            StudyAchievementPresentationModel.closestInProgress(
                catalog: catalog,
                progress: progress
            ).map(\.id),
            ["reviews.first", "voice.first", "stable.first"]
        )
    }

    func testCatalogRejectsWrongRetinaDimensionsAndUnsafePaths() throws {
        var catalog = makeCatalog()
        catalog = replacingFirstAsset(
            in: catalog,
            key: "512",
            asset: asset(size: 256)
        )
        XCTAssertThrowsError(try catalog.validated()) { error in
            XCTAssertEqual(error as? StudyAchievementCatalogError, .invalidAsset)
        }

        catalog = makeCatalog()
        catalog = replacingFirstAsset(
            in: catalog,
            key: "256",
            asset: asset(size: 256, path: "/achievement-assets/../private.png")
        )
        XCTAssertThrowsError(try catalog.validated()) { error in
            XCTAssertEqual(error as? StudyAchievementCatalogError, .invalidAsset)
        }
    }

    func testCatalogRejectsMissingEarnedDescription() {
        let catalog = replacingFirstEarnedDescription(in: makeCatalog(), with: "")

        XCTAssertThrowsError(try catalog.validated()) { error in
            XCTAssertEqual(error as? StudyAchievementCatalogError, .invalidStructure)
        }
    }

    @MainActor
    func testStoreLoadsCatalogAndAuthenticatedProgressFromCanonicalEndpoints() async throws {
        let catalogPayload = try JSONEncoder().encode(makeCatalog())
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = { request in
            let path = request.url?.path
            let body: Data
            switch path {
            case "/api/achievements/catalog":
                body = catalogPayload
            case "/api/achievements/evaluate":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer achievement-token"
                )
                body = Data(
                    #"{"revision":"achievement-collection-v2","metricValues":{"stable.count":0,"reviews.count":120,"voice.hours":20},"awards":[{"id":"reviews.first","earnedAt":"2026-01-01T00:00:00.000Z"},{"id":"reviews.second","earnedAt":"2026-02-01T00:00:00.000Z"}]}"#.utf8
                )
            default:
                XCTFail("Unexpected achievement request: \(path ?? "nil")")
                body = Data()
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                body
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        Self.retainedClients.append(client)
        client.setAccessToken("achievement-token")
        let store = StudyAchievementStore(api: client)
        store.activate(userID: 41)

        await store.refresh()

        XCTAssertEqual(store.catalog?.revision, "achievement-collection-v2")
        XCTAssertEqual(store.progress?.metricValues["reviews.count"], 120)
        XCTAssertEqual(
            store.earnedAchievements.map(\.id),
            ["reviews.second", "reviews.first"]
        )
    }

    @MainActor
    func testStoreSurfacesInitialProgressFailureInsteadOfShowingEmptyHistory() async throws {
        let catalogPayload = try JSONEncoder().encode(makeCatalog())
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/achievements/catalog" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    catalogPayload
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"message":"Unavailable"}"#.utf8)
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        Self.retainedClients.append(client)
        client.setAccessToken("achievement-token")
        let store = StudyAchievementStore(api: client)
        store.activate(userID: 41)

        await store.refresh()

        XCTAssertNotNil(store.catalog)
        XCTAssertNil(store.progress)
        XCTAssertEqual(store.progressErrorMessage, "Your badges couldn’t be refreshed right now.")
        XCTAssertTrue(store.earnedAchievements.isEmpty)
        XCTAssertEqual(
            store.inProgressAchievements.map(\.id),
            ["reviews.first", "voice.first", "stable.first"]
        )
    }

    @MainActor
    func testAccountSwitchDropsStaleRefreshAndForcedRefreshWaitsForInFlightLoad() async throws {
        let catalogPayload = try JSONEncoder().encode(makeCatalog())
        let (requests, requestContinuation) = AsyncStream<(
            URLRequest,
            MockURLProtocol.DeferredCompletion
        )>.makeStream()
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = { request, completion in
            requestContinuation.yield((request, completion))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
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
        guard let (staleProgressRequest, staleProgressCompletion) = await iterator.next() else {
            return XCTFail("Expected the stale progress request")
        }
        staleProgressCompletion(.success(response(
            for: staleProgressRequest,
            data: progressPayload(reviews: 120)
        )))
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
        initialProgressCompletion(.success(response(
            for: initialProgressRequest,
            data: progressPayload(reviews: 25)
        )))
        await initialRefresh.value

        guard let (forcedCatalogRequest, forcedCatalogCompletion) = await iterator.next() else {
            return XCTFail("Expected the forced catalog request after the in-flight load")
        }
        forcedCatalogCompletion(.success(response(for: forcedCatalogRequest, data: catalogPayload)))
        guard let (forcedProgressRequest, forcedProgressCompletion) = await iterator.next() else {
            return XCTFail("Expected the forced progress request")
        }
        forcedProgressCompletion(.success(response(
            for: forcedProgressRequest,
            data: progressPayload(reviews: 50)
        )))
        await forcedRefresh.value

        XCTAssertEqual(store.progress?.metricValues["reviews.count"], 50)
    }

    private func makeCatalog() -> StudyAchievementCatalog {
        StudyAchievementCatalog(
            revision: "achievement-collection-v2",
            presentation: StudyAchievementPresentation(
                targetVisibleBadgeCount: 3,
                fillWithLockedCandidates: true,
                noDataFallbackTierIds: ["reviews.first", "voice.first", "stable.first"]
            ),
            families: [
                family(key: "stable", title: "Stable", metric: "stable.count", unit: "cards"),
                family(key: "reviews", title: "Reviews", metric: "reviews.count", unit: "reviews"),
                family(key: "voice", title: "Voice", metric: "voice.hours", unit: "hours"),
            ]
        )
    }

    private func family(
        key: String,
        title: String,
        metric: String,
        unit: String
    ) -> StudyAchievementFamily {
        StudyAchievementFamily(
            key: key,
            title: title,
            metricKey: metric,
            unit: unit,
            hiddenUntilEarned: nil,
            tiers: [
                tier(key: "first", title: "\(title) 1", threshold: 25),
                tier(key: "second", title: "\(title) 2", threshold: 100),
            ]
        )
    }

    private func tier(key: String, title: String, threshold: Int) -> StudyAchievementTier {
        let state = StudyAchievementPNGAssets(
            png: ["256": asset(size: 256), "512": asset(size: 512)]
        )
        return StudyAchievementTier(
            key: key,
            title: title,
            threshold: threshold,
            description: "Earn \(threshold)",
            earnedDescription: "Completed \(threshold) reviews",
            assets: StudyAchievementTierAssets(earned: state, locked: state)
        )
    }

    private func asset(size: Int, path: String? = nil) -> StudyAchievementAsset {
        StudyAchievementAsset(
            path: path ?? "/achievement-assets/test-\(size).png",
            width: size,
            height: size
        )
    }

    private func progressPayload(reviews: Int) -> Data {
        Data(
            """
            {"revision":"achievement-collection-v2","metricValues":{"stable.count":0,"reviews.count":\(reviews),"voice.hours":20},"awards":[]}
            """.utf8
        )
    }

    private func award(id: String, date: String) -> StudyAchievementAward {
        StudyAchievementAward(id: id, earnedAt: ISO8601Milliseconds.date(from: date)!)
    }

    private func response(
        for request: URLRequest,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            data
        )
    }

    private func replacingFirstAsset(
        in catalog: StudyAchievementCatalog,
        key: String,
        asset: StudyAchievementAsset
    ) -> StudyAchievementCatalog {
        var families = catalog.families
        let family = families[0]
        var tiers = family.tiers
        let tier = tiers[0]
        var png = tier.assets.earned.png
        png[key] = asset
        tiers[0] = StudyAchievementTier(
            key: tier.key,
            title: tier.title,
            threshold: tier.threshold,
            description: tier.description,
            earnedDescription: tier.earnedDescription,
            assets: StudyAchievementTierAssets(
                earned: StudyAchievementPNGAssets(png: png),
                locked: tier.assets.locked
            )
        )
        families[0] = StudyAchievementFamily(
            key: family.key,
            title: family.title,
            metricKey: family.metricKey,
            unit: family.unit,
            hiddenUntilEarned: family.hiddenUntilEarned,
            tiers: tiers
        )
        return StudyAchievementCatalog(
            revision: catalog.revision,
            presentation: catalog.presentation,
            families: families
        )
    }

    private func replacingFirstEarnedDescription(
        in catalog: StudyAchievementCatalog,
        with earnedDescription: String
    ) -> StudyAchievementCatalog {
        var families = catalog.families
        let family = families[0]
        var tiers = family.tiers
        let tier = tiers[0]
        tiers[0] = StudyAchievementTier(
            key: tier.key,
            title: tier.title,
            threshold: tier.threshold,
            description: tier.description,
            earnedDescription: earnedDescription,
            assets: tier.assets
        )
        families[0] = StudyAchievementFamily(
            key: family.key,
            title: family.title,
            metricKey: family.metricKey,
            unit: family.unit,
            hiddenUntilEarned: family.hiddenUntilEarned,
            tiers: tiers
        )
        return StudyAchievementCatalog(
            revision: catalog.revision,
            presentation: catalog.presentation,
            families: families
        )
    }

}
