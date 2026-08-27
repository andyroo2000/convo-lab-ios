import XCTest
@testable import ConvoLab

final class StudyAchievementTests: XCTestCase {
    private nonisolated(unsafe) static var retainedClients: [APIClient] = []

    func testNoDataUsesCanonicalFallbackOrder() throws {
        let catalog = try makeCatalog().validated()

        let featured = StudyAchievementPresentationModel.featured(
            catalog: catalog,
            progress: nil
        )

        XCTAssertEqual(
            featured.map(\.id),
            ["reviews.first", "voice.first", "stable.first"]
        )
        XCTAssertTrue(featured.allSatisfy { !$0.isEarned && $0.currentValue == nil })
    }

    func testFeaturedShowsStrongestEarnedTierAndFillsUnrepresentedFamilies() throws {
        let catalog = try makeCatalog().validated()
        let progress = StudyAchievementProgress(
            revision: catalog.revision,
            metricValues: [
                "stable.count": 0,
                "reviews.count": 120,
                "voice.minutes": 20,
            ]
        )

        let featured = StudyAchievementPresentationModel.featured(
            catalog: catalog,
            progress: progress
        )

        XCTAssertEqual(featured.map(\.id), ["reviews.second", "voice.first", "stable.first"])
        XCTAssertEqual(featured.map(\.isEarned), [true, false, false])
    }

    func testRevisionMismatchFallsBackInsteadOfApplyingStaleMetrics() throws {
        let catalog = try makeCatalog().validated()
        let progress = StudyAchievementProgress(
            revision: "future-revision",
            metricValues: ["reviews.count": 10_000]
        )

        XCTAssertEqual(
            StudyAchievementPresentationModel.featured(
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
            case "/api/achievements/progress":
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer achievement-token"
                )
                body = Data(
                    #"{"revision":"achievement-collection-v1","metricValues":{"stable.count":0,"reviews.count":120,"voice.minutes":20}}"#.utf8
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

        XCTAssertEqual(store.catalog?.revision, "achievement-collection-v1")
        XCTAssertEqual(store.progress?.metricValues["reviews.count"], 120)
        XCTAssertEqual(
            store.featuredAchievements.map(\.id),
            ["reviews.second", "voice.first", "stable.first"]
        )
    }

    private func makeCatalog() -> StudyAchievementCatalog {
        StudyAchievementCatalog(
            revision: "achievement-collection-v1",
            presentation: StudyAchievementPresentation(
                targetVisibleBadgeCount: 3,
                fillWithLockedCandidates: true,
                noDataFallbackTierIds: ["reviews.first", "voice.first", "stable.first"]
            ),
            families: [
                family(key: "stable", title: "Stable", metric: "stable.count", unit: "cards"),
                family(key: "reviews", title: "Reviews", metric: "reviews.count", unit: "reviews"),
                family(key: "voice", title: "Voice", metric: "voice.minutes", unit: "minutes"),
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
            tiers: tiers
        )
        return StudyAchievementCatalog(
            revision: catalog.revision,
            presentation: catalog.presentation,
            families: families
        )
    }

}
