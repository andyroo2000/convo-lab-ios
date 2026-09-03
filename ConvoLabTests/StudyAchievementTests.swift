import XCTest
@testable import ConvoLab

final class StudyAchievementTests: XCTestCase {
    nonisolated(unsafe) static var retainedClients: [APIClient] = []

    private struct FamilyFixture {
        let key: String
        let title: String
        let metric: String
        let unit: String

        static let stable = Self(key: "stable", title: "Stable", metric: "stable.count", unit: "cards")
        static let reviews = Self(key: "reviews", title: "Reviews", metric: "reviews.count", unit: "reviews")
        static let voice = Self(key: "voice", title: "Voice", metric: "voice.hours", unit: "hours")
    }

    private struct TierFixture {
        let key: String
        let titleSuffix: String
        let threshold: Int
        let assetSuffix: String

        static let first = Self(key: "first", titleSuffix: "1", threshold: 25, assetSuffix: "first")
        static let second = Self(key: "second", titleSuffix: "2", threshold: 100, assetSuffix: "second")
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    func testNoDataUsesCanonicalFallbackOrder() throws {
        let catalog = try makeCatalog().validated()

        let featured = StudyAchievementPresentationModel.closestInProgress(catalog: catalog, progress: nil)

        XCTAssertEqual(featured.map(\.id), ["reviews.first", "voice.first", "stable.first"])
        XCTAssertTrue(featured.allSatisfy { !$0.isEarned && $0.currentValue == nil })
    }

    func testNewAccountUsesCanonicalFallbackOrderBeforeProgressStarts() throws {
        let catalog = try makeCatalog().validated()
        let progress = StudyAchievementProgress(
            revision: catalog.revision, metricValues: ["stable.count": 0, "reviews.count": 0, "voice.hours": 0],
            awards: [])

        XCTAssertEqual(
            StudyAchievementPresentationModel.closestInProgress(catalog: catalog, progress: progress).map(\.id),
            ["reviews.first", "voice.first", "stable.first"])
    }

    func testInProgressShowsOnlyTheNextLockedTierPerFamily() throws {
        let catalog = try makeCatalog().validated()
        let progress = StudyAchievementProgress(
            revision: catalog.revision, metricValues: ["stable.count": 0, "reviews.count": 120, "voice.hours": 20],
            awards: [
                award(id: "reviews.first", date: "2026-01-01T00:00:00.000Z"),
                award(id: "reviews.second", date: "2026-02-01T00:00:00.000Z"),
            ])

        let featured = StudyAchievementPresentationModel.closestInProgress(catalog: catalog, progress: progress)

        XCTAssertEqual(featured.map(\.id), ["voice.first", "stable.first"])
        XCTAssertTrue(featured.allSatisfy { !$0.isEarned })
    }

    func testHiddenFamilyStaysOutOfInProgressButAppearsAfterItIsEarned() throws {
        var catalog = makeCatalog()
        let family = catalog.families[0]
        var families = catalog.families
        families[0] = StudyAchievementFamily(
            key: family.key, title: family.title, metricKey: family.metricKey, unit: family.unit,
            hiddenUntilEarned: true, tiers: family.tiers)
        catalog = try StudyAchievementCatalog(
            revision: catalog.revision, presentation: catalog.presentation, families: families
        ).validated()

        let noProgress = StudyAchievementPresentationModel.closestInProgress(catalog: catalog, progress: nil)
        XCTAssertFalse(noProgress.map(\.id).contains("stable.first"))

        let inProgress = StudyAchievementPresentationModel.closestInProgress(
            catalog: catalog,
            progress: StudyAchievementProgress(
                revision: catalog.revision, metricValues: ["stable.count": 24, "reviews.count": 1, "voice.hours": 1],
                awards: []))
        XCTAssertFalse(inProgress.map(\.id).contains("stable.first"))

        let earned = StudyAchievementPresentationModel.recentEarned(
            catalog: catalog,
            progress: StudyAchievementProgress(
                revision: catalog.revision, metricValues: ["stable.count": 25],
                awards: [award(id: "stable.first", date: "2026-01-01T00:00:00.000Z")]))
        XCTAssertTrue(earned.map(\.id).contains("stable.first"))
    }

    func testEarnedHistoryIncludesEveryAwardNewestFirst() throws {
        let catalog = try makeCatalog().validated()
        let earned = StudyAchievementPresentationModel.recentEarned(
            catalog: catalog,
            progress: StudyAchievementProgress(
                revision: catalog.revision,
                metricValues: ["stable.count": 100, "reviews.count": 120, "voice.hours": 100],
                awards: [
                    award(id: "stable.first", date: "2026-01-01T00:00:00.000Z"),
                    award(id: "reviews.second", date: "2026-03-01T00:00:00.000Z"),
                    award(id: "voice.first", date: "2026-02-01T00:00:00.000Z"),
                ]), count: .max)

        XCTAssertEqual(earned.map(\.id), ["reviews.second", "voice.first", "stable.first"])
    }

    func testRevisionMismatchFallsBackInsteadOfApplyingStaleMetrics() throws {
        let catalog = try makeCatalog().validated()
        let progress = StudyAchievementProgress(
            revision: "future-revision", metricValues: ["reviews.count": 10_000],
            awards: [award(id: "reviews.second", date: "2026-01-01T00:00:00.000Z")])

        XCTAssertEqual(
            StudyAchievementPresentationModel.closestInProgress(catalog: catalog, progress: progress).map(\.id),
            ["reviews.first", "voice.first", "stable.first"])
    }

    func testCatalogRejectsWrongRetinaDimensionsAndUnsafePaths() throws {
        var catalog = makeCatalog()
        catalog = replacingFirstAsset(in: catalog, key: "512", asset: asset(size: 256))
        XCTAssertThrowsError(try catalog.validated()) { error in
            XCTAssertEqual(error as? StudyAchievementCatalogError, .invalidAsset)
        }

        catalog = makeCatalog()
        catalog = replacingFirstAsset(
            in: catalog, key: "256", asset: asset(size: 256, path: "/achievement-assets/../private.png"))
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

    func makeCatalog() -> StudyAchievementCatalog {
        StudyAchievementCatalog(
            revision: "achievement-collection-v2",
            presentation: StudyAchievementPresentation(
                targetVisibleBadgeCount: 3, fillWithLockedCandidates: true,
                noDataFallbackTierIds: ["reviews.first", "voice.first", "stable.first"]),
            families: [family(.stable), family(.reviews), family(.voice)])
    }

    private func family(_ fixture: FamilyFixture) -> StudyAchievementFamily {
        StudyAchievementFamily(
            key: fixture.key, title: fixture.title, metricKey: fixture.metric, unit: fixture.unit,
            hiddenUntilEarned: nil, tiers: [tier(.first, in: fixture), tier(.second, in: fixture)])
    }

    private func tier(_ tierFixture: TierFixture, in familyFixture: FamilyFixture) -> StudyAchievementTier {
        let assetPrefix = "\(familyFixture.key)-\(tierFixture.assetSuffix)"
        let earned = StudyAchievementPNGAssets(png: [
            "256": asset(size: 256, path: "/achievement-assets/\(assetPrefix)-earned-256.png"),
            "512": asset(size: 512, path: "/achievement-assets/\(assetPrefix)-earned-512.png"),
        ])
        let locked = StudyAchievementPNGAssets(png: [
            "256": asset(size: 256, path: "/achievement-assets/\(assetPrefix)-locked-256.png"),
            "512": asset(size: 512, path: "/achievement-assets/\(assetPrefix)-locked-512.png"),
        ])
        return StudyAchievementTier(
            key: tierFixture.key, title: "\(familyFixture.title) \(tierFixture.titleSuffix)",
            threshold: tierFixture.threshold, description: "Earn \(tierFixture.threshold)",
            earnedDescription: "Completed \(tierFixture.threshold) reviews",
            assets: StudyAchievementTierAssets(earned: earned, locked: locked))
    }

    func asset(size: Int, path: String? = nil) -> StudyAchievementAsset {
        StudyAchievementAsset(path: path ?? "/achievement-assets/test-\(size).png", width: size, height: size)
    }

    func progressPayload(reviews: Int) -> Data {
        Data(
            """
            {"revision":"achievement-collection-v2","metricValues":{"stable.count":0,"reviews.count":\(reviews),"voice.hours":20},"awards":[]}
            """.utf8)
    }

    @MainActor
    func makeClient() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!, session: URLSession(configuration: configuration))
        Self.retainedClients.append(client)
        return client
    }

    func installAchievementResponses(awards: [StudyAchievementAward]) throws {
        let catalog = makeCatalog()
        let catalogPayload = try JSONEncoder().encode(catalog)
        let progressPayload = try achievementProgressPayload(awards: awards)
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = { request in
            let body =
                switch request.url?.path {
                case "/api/achievements/catalog": catalogPayload
                case "/api/achievements/evaluate": progressPayload
                default: Data()
                }
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: body.isEmpty ? 404 : 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!, body
            )
        }
    }

    func achievementProgressPayload(awards: [StudyAchievementAward]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "revision": makeCatalog().revision,
            "metricValues": ["stable.count": 0, "reviews.count": 25, "voice.hours": 25],
            "awards": awards.map { ["id": $0.id, "earnedAt": ISO8601Milliseconds.string(from: $0.earnedAt)] },
        ])
    }

    @MainActor
    func makeReviewRecord(id: String, reviewedAt: Date = .now) -> StudySessionReviewRecord {
        let card = StudyCard(
            id: "card-\(id)", syncId: nil, noteId: nil, cardType: "recognition",
            prompt: .object(["cueText": .string("Prompt")]), answer: .object(["meaning": .string("Answer")]),
            state: .init(
                dueAt: .now, introducedAt: .now, failedAt: nil, queueState: "review",
                scheduler: .object(["stability": .number(10)]), source: .object([:])), answerAudioSource: nil,
            createdAt: .now, updatedAt: .now)
        return StudySessionReviewRecord(
            id: id, cardBefore: card, cardAfter: card, rating: .good, durationMilliseconds: 1_000,
            reviewedAt: reviewedAt)
    }

    func award(id: String, date: String) -> StudyAchievementAward {
        StudyAchievementAward(id: id, earnedAt: ISO8601Milliseconds.date(from: date)!)
    }

    func response(for request: URLRequest, data: Data) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!, data
        )
    }

    func replacingFirstAsset(in catalog: StudyAchievementCatalog, key: String, asset: StudyAchievementAsset)
        -> StudyAchievementCatalog
    {
        var families = catalog.families
        let family = families[0]
        var tiers = family.tiers
        let tier = tiers[0]
        var png = tier.assets.earned.png
        png[key] = asset
        tiers[0] = StudyAchievementTier(
            key: tier.key, title: tier.title, threshold: tier.threshold, description: tier.description,
            earnedDescription: tier.earnedDescription,
            assets: StudyAchievementTierAssets(earned: StudyAchievementPNGAssets(png: png), locked: tier.assets.locked))
        families[0] = StudyAchievementFamily(
            key: family.key, title: family.title, metricKey: family.metricKey, unit: family.unit,
            hiddenUntilEarned: family.hiddenUntilEarned, tiers: tiers)
        return StudyAchievementCatalog(
            revision: catalog.revision, presentation: catalog.presentation, families: families)
    }

    func replacingFirstEarnedDescription(in catalog: StudyAchievementCatalog, with earnedDescription: String)
        -> StudyAchievementCatalog
    {
        var families = catalog.families
        let family = families[0]
        var tiers = family.tiers
        let tier = tiers[0]
        tiers[0] = StudyAchievementTier(
            key: tier.key, title: tier.title, threshold: tier.threshold, description: tier.description,
            earnedDescription: earnedDescription, assets: tier.assets)
        families[0] = StudyAchievementFamily(
            key: family.key, title: family.title, metricKey: family.metricKey, unit: family.unit,
            hiddenUntilEarned: family.hiddenUntilEarned, tiers: tiers)
        return StudyAchievementCatalog(
            revision: catalog.revision, presentation: catalog.presentation, families: families)
    }

    func makeDefaults() throws -> UserDefaults {
        let name = "StudyAchievementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
