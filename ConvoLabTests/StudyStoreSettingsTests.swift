import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testStudySettingsRoundTripsAPILaneWeights() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let expected = StudyNewCardLaneWeights(
            standard: 4,
            lessonFollowup: 2,
            wanikani: 1
        )
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/settings")
            if request.httpMethod == "PATCH" {
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: requestBody(request))
                        as? [String: Any]
                )
                let weights = try XCTUnwrap(
                    body["newCardLaneWeights"] as? [String: Int]
                )
                XCTAssertEqual(weights, [
                    "standard": 4,
                    "lessonFollowup": 2,
                    "wanikani": 1,
                ])
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    #"{"newCardsPerDay":20,"lessonBatchSize":5,"reviewTimeBudgetMinutes":90,"newCardLaneWeights":{"standard":4,"lessonFollowup":2,"wanikani":1}}"#.utf8
                )
            )
        }
        let store = makeSettingsStore(in: container, client: client)

        await store.refreshStudySettings()
        XCTAssertEqual(store.studySettings?.newCardLaneWeights, expected)

        let saved = await store.updateStudySettings(
            newCardsPerDay: 20,
            lessonBatchSize: 5,
            reviewTimeBudgetMinutes: 90,
            newCardLaneWeights: expected
        )

        XCTAssertTrue(saved)
        XCTAssertEqual(store.studySettings?.newCardLaneWeights, expected)
    }

    @MainActor
    func testStudySettingsRefreshAndUpdateUseCompatibilityPayload() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/settings")
            if request.httpMethod == "PATCH" {
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Int]
                )
                XCTAssertEqual(body, [
                    "lessonBatchSize": 5,
                    "newCardsPerDay": 24,
                ])
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"newCardsPerDay":24}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"newCardsPerDay":12}"#.utf8)
            )
        }
        let store = makeSettingsStore(in: container, client: client)
        await store.refreshStudySettings()
        XCTAssertEqual(store.studySettings?.newCardsPerDay, 12)
        XCTAssertEqual(store.studySettings?.lessonBatchSize, 5)
        XCTAssertEqual(store.studySettings?.reviewTimeBudgetMinutes, 90)

        let saved = await store.updateNewCardsPerDay(24)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.studySettings?.newCardsPerDay, 24)
        XCTAssertNil(store.studySettingsErrorMessage)
    }

    @MainActor
    func testNewCardLimitUpdateUsesAdvertisedLessonDefaultWithoutLoadedSettings() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Int]
            )
            XCTAssertEqual(body["lessonBatchSize"], 7)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"newCardsPerDay":24,"lessonBatchSize":7}"#.utf8)
            )
        }
        let store = makeSettingsStore(in: container, client: client)
        let fallback = StudyCapabilities.fallback
        store.capabilities = StudyCapabilities(
            version: fallback.version,
            settings: .init(
                newCardsPerDay: fallback.settings.newCardsPerDay,
                lessonBatchSize: .init(default: 7, min: 3, max: 10),
                reviewTimeBudgetMinutes: fallback.settings.reviewTimeBudgetMinutes,
                newCardLaneWeights: fallback.settings.newCardLaneWeights
            ),
            cardAuthoring: fallback.cardAuthoring,
            dailyAudio: fallback.dailyAudio,
            offlineReserve: fallback.offlineReserve,
            imports: fallback.imports,
            studyActivity: fallback.studyActivity
        )

        let saved = await store.updateNewCardsPerDay(24)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.studySettings?.lessonBatchSize, 7)
    }

    @MainActor
    func testOlderSettingsRefreshCannotOverwriteNewerSavedSettings() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let deferredRefresh = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            XCTAssertEqual(request.url?.path, "/api/study/settings")
            if request.httpMethod == "PATCH" {
                completion(.success(Self.response(data: Data(
                    #"{"newCardsPerDay":24,"lessonBatchSize":8,"reviewTimeBudgetMinutes":150}"#.utf8
                ))))
            } else {
                deferredRefresh.hold(completion)
            }
        }
        let store = makeSettingsStore(in: container, client: client)

        let refresh = Task { await store.refreshStudySettings() }
        await waitUntil { deferredRefresh.hasPendingResponse }
        let saved = await store.updateStudySettings(
            newCardsPerDay: 24,
            lessonBatchSize: 8,
            reviewTimeBudgetMinutes: 150
        )
        XCTAssertTrue(saved)
        XCTAssertEqual(store.studySettings?.newCardsPerDay, 24)

        deferredRefresh.succeed(with: Self.response(data: Data(
            #"{"newCardsPerDay":12,"lessonBatchSize":5,"reviewTimeBudgetMinutes":90}"#.utf8
        )))
        await refresh.value

        XCTAssertEqual(store.studySettings?.newCardsPerDay, 24)
        XCTAssertEqual(store.studySettings?.lessonBatchSize, 8)
        XCTAssertEqual(store.studySettings?.reviewTimeBudgetMinutes, 150)
    }

    @MainActor
    func testSettingsRefreshCannotDiscardInFlightSave() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let deferredUpdate = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            XCTAssertEqual(request.url?.path, "/api/study/settings")
            if request.httpMethod == "PATCH" {
                deferredUpdate.hold(completion)
            } else {
                completion(.success(Self.response(data: Data(
                    #"{"newCardsPerDay":12,"lessonBatchSize":5,"reviewTimeBudgetMinutes":90}"#.utf8
                ))))
            }
        }
        let store = makeSettingsStore(in: container, client: client)

        let update = Task {
            await store.updateStudySettings(
                newCardsPerDay: 24,
                lessonBatchSize: 8,
                reviewTimeBudgetMinutes: 150
            )
        }
        await waitUntil { deferredUpdate.hasPendingResponse }
        await store.refreshStudySettings()
        XCTAssertEqual(store.studySettings?.newCardsPerDay, 12)

        deferredUpdate.succeed(with: Self.response(data: Data(
            #"{"newCardsPerDay":24,"lessonBatchSize":8,"reviewTimeBudgetMinutes":150}"#.utf8
        )))
        let saved = await update.value

        XCTAssertTrue(saved)
        XCTAssertEqual(store.studySettings?.newCardsPerDay, 24)
        XCTAssertEqual(store.studySettings?.lessonBatchSize, 8)
        XCTAssertEqual(store.studySettings?.reviewTimeBudgetMinutes, 150)
    }

    @MainActor
    func testOverviewRefreshSendsDeviceTimeZone() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let expectedTimeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/overview")
            let queryItems = try XCTUnwrap(
                URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems
            )
            XCTAssertEqual(
                queryItems.first(where: { $0.name == "time_zone" })?.value,
                expectedTimeZone.identifier
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    #"{"dueCount":0,"newCount":0,"reviewCount":0,"newCardsPerDay":20}"#.utf8
                )
            )
        }
        let store = makeSettingsStore(in: container, client: client)

        await store.refreshOverview(timeZone: expectedTimeZone)

        XCTAssertNil(store.overviewRefreshErrorMessage)
    }

    @MainActor
    func testOverviewRefreshPublishesSeparateN5VocabularyAndGrammarMastery() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/overview")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    #"{"dueCount":0,"newCount":0,"reviewCount":0,"newCardsPerDay":20,"jlptMastery":{"N5":{"vocabulary":{"masteryPercent":34,"known":233,"matched":280,"covered":280,"total":684},"grammar":{"masteryPercent":21,"known":16,"matched":29,"covered":29,"total":77}}}}"#.utf8
                )
            )
        }
        let store = makeSettingsStore(in: container, client: client)

        await store.refreshOverview()

        XCTAssertEqual(store.overview?.jlptMastery?.n5.vocabulary.masteryPercent, 34)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.vocabulary.known, 233)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.vocabulary.matched, 280)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.vocabulary.total, 684)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.grammar.masteryPercent, 21)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.grammar.known, 16)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.grammar.matched, 29)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.grammar.total, 77)
        XCTAssertFalse(store.isRefreshingOverview)
        XCTAssertNil(store.overviewRefreshErrorMessage)
    }

    @MainActor
    func testOverviewRefreshPreservesMasteryWhenResponseOmitsIt() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        container.mainContext.insert(LocalStudyOverviewSnapshot(
            userID: 1,
            payload: try StorageCodec.encoder.encode(StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 20,
                newCardsAvailableToday: 0,
                jlptMastery: StudyJLPTMastery(
                    n5: StudyJLPTLevelMastery(
                        vocabulary: StudyJLPTMasteryMetric(
                            masteryPercent: 8,
                            covered: 83,
                            total: 684
                        ),
                        grammar: StudyJLPTMasteryMetric(
                            masteryPercent: 46,
                            covered: 36,
                            total: 77
                        )
                    )
                )
            ))
        ))
        try container.mainContext.save()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/overview")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    #"{"dueCount":2,"newCount":0,"reviewCount":2,"newCardsPerDay":20}"#.utf8
                )
            )
        }
        let store = makeSettingsStore(in: container, client: client)

        await store.refreshOverview()

        XCTAssertEqual(store.overview?.dueCount, 2)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.vocabulary.masteryPercent, 8)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.grammar.masteryPercent, 46)
    }

    @MainActor
    func testOverviewRefreshCannotOverwriteNewerSavedSettings() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let deferredOverview = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            switch (request.url?.path, request.httpMethod) {
            case ("/api/study/settings", "GET"):
                completion(.success(Self.response(data: Data(
                    #"{"newCardsPerDay":12,"lessonBatchSize":5,"reviewTimeBudgetMinutes":90}"#.utf8
                ))))
            case ("/api/study/settings", "PATCH"):
                completion(.success(Self.response(data: Data(
                    #"{"newCardsPerDay":24,"lessonBatchSize":8,"reviewTimeBudgetMinutes":150}"#.utf8
                ))))
            case ("/api/study/overview", "GET"):
                deferredOverview.hold(completion)
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                completion(.failure(URLError(.unsupportedURL)))
            }
        }
        let store = makeSettingsStore(in: container, client: client)
        await store.refreshStudySettings()

        let refresh = Task { await store.refreshOverview() }
        await deferredOverview.waitUntilPending()
        let saved = await store.updateStudySettings(
            newCardsPerDay: 24,
            lessonBatchSize: 8,
            reviewTimeBudgetMinutes: 150
        )
        XCTAssertTrue(saved)

        deferredOverview.succeed(with: Self.response(data: Data(
            #"{"dueCount":3,"newCount":4,"reviewCount":7,"newCardsPerDay":12,"lessonBatchSize":5,"reviewTimeBudgetMinutes":90}"#.utf8
        )))
        await refresh.value

        XCTAssertEqual(store.overview?.dueCount, 3)
        XCTAssertEqual(store.studySettings?.newCardsPerDay, 24)
        XCTAssertEqual(store.studySettings?.lessonBatchSize, 8)
        XCTAssertEqual(store.studySettings?.reviewTimeBudgetMinutes, 150)
        XCTAssertEqual(store.overview?.newCardsPerDay, 24)
        XCTAssertEqual(store.overview?.lessonBatchSize, 8)
        XCTAssertEqual(store.overview?.reviewTimeBudgetMinutes, 150)
    }

    @MainActor
    func testSessionRefreshPreservesBudgetAndMasteryWhenResponseFieldsAreAbsent() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        container.mainContext.insert(LocalStudyOverviewSnapshot(
            userID: 1,
            payload: try StorageCodec.encoder.encode(StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 20,
                newCardsAvailableToday: 0,
                jlptMastery: StudyJLPTMastery(
                    n5: StudyJLPTLevelMastery(
                        vocabulary: StudyJLPTMasteryMetric(
                            masteryPercent: 8,
                            covered: 83,
                            total: 684
                        ),
                        grammar: StudyJLPTMasteryMetric(
                            masteryPercent: 46,
                            covered: 36,
                            total: 77
                        )
                    )
                )
            ))
        ))
        try container.mainContext.save()
        let sessionData = try readinessSessionResponseData(
            reviewTimeBudgetMinutes: nil,
            reviewTimeHeadroomMinutes: nil
        )
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/settings":
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(
                        #"{"newCardsPerDay":20,"lessonBatchSize":5,"reviewTimeBudgetMinutes":150}"#.utf8
                    )
                )
            case "/api/study/session/start":
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    sessionData
                )
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let store = makeSettingsStore(in: container, client: client)

        await store.refreshStudySettings()
        try await store.refreshSession()

        XCTAssertEqual(store.studySettings?.reviewTimeBudgetMinutes, 150)
        XCTAssertEqual(store.overview?.reviewTimeBudgetMinutes, 150)
        XCTAssertEqual(store.overview?.learningReadiness?.reviewTimeBudgetMinutes, 150)
        XCTAssertEqual(store.overview?.learningReadiness?.reviewTimeHeadroomMinutes, 90)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.vocabulary.masteryPercent, 8)
        XCTAssertEqual(store.overview?.jlptMastery?.n5.grammar.masteryPercent, 46)
    }

    @MainActor
    func testSettingsRefreshUpdatesOverviewReadinessBudget() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let sessionData = try readinessSessionResponseData(
            reviewTimeBudgetMinutes: 90,
            reviewTimeHeadroomMinutes: 30
        )
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/session/start":
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    sessionData
                )
            case "/api/study/settings":
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(
                        #"{"newCardsPerDay":24,"lessonBatchSize":8,"reviewTimeBudgetMinutes":150}"#.utf8
                    )
                )
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let store = makeSettingsStore(in: container, client: client)

        try await store.refreshSession()
        await store.refreshStudySettings()

        XCTAssertEqual(store.overview?.newCardsPerDay, 24)
        XCTAssertEqual(store.overview?.lessonBatchSize, 8)
        XCTAssertEqual(store.studySettings?.reviewTimeBudgetMinutes, 150)
        XCTAssertEqual(store.overview?.reviewTimeBudgetMinutes, 150)
        XCTAssertEqual(store.overview?.learningReadiness?.reviewTimeBudgetMinutes, 150)
        XCTAssertEqual(store.overview?.learningReadiness?.reviewTimeHeadroomMinutes, 90)
    }

    @MainActor
    func testStudySettingsUpdateSendsAnExplicitReviewBudget() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/settings")
            XCTAssertEqual(request.httpMethod, "PATCH")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Int]
            )
            XCTAssertEqual(body, [
                "lessonBatchSize": 5,
                "newCardsPerDay": 20,
                "reviewTimeBudgetMinutes": 150,
            ])

            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    #"{"newCardsPerDay":20,"lessonBatchSize":5,"reviewTimeBudgetMinutes":150}"#.utf8
                )
            )
        }
        let store = makeSettingsStore(in: container, client: client)

        let saved = await store.updateStudySettings(
            newCardsPerDay: 20,
            lessonBatchSize: 5,
            reviewTimeBudgetMinutes: 150
        )

        XCTAssertTrue(saved)
        XCTAssertEqual(store.studySettings?.reviewTimeBudgetMinutes, 150)
    }

    @MainActor
    func testLegacySettingsResponsePreservesExplicitReviewBudget() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/settings")
            XCTAssertEqual(request.httpMethod, "PATCH")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"newCardsPerDay":20,"lessonBatchSize":5}"#.utf8)
            )
        }
        let store = makeSettingsStore(in: container, client: client)

        let saved = await store.updateStudySettings(
            newCardsPerDay: 20,
            lessonBatchSize: 5,
            reviewTimeBudgetMinutes: 150
        )

        XCTAssertTrue(saved)
        XCTAssertEqual(store.studySettings?.reviewTimeBudgetMinutes, 150)
    }

    @MainActor
    private func makeSettingsStore(
        in container: ModelContainer,
        client: APIClient
    ) -> StudyStore {
        StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )
    }

    @MainActor
    private func readinessSessionResponseData(
        reviewTimeBudgetMinutes: Int?,
        reviewTimeHeadroomMinutes: Int?
    ) throws -> Data {
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 0,
                reviewCount: 0,
                newCardsPerDay: 20,
                newCardsAvailableToday: 0,
                learningReadiness: StudyLearningReadiness(
                    recommendation: "ready",
                    readinessLevel: "ready",
                    sampleSize: 40,
                    sufficientData: true,
                    recentRecall: 0.95,
                    targetRecall: 0.9,
                    dueBacklog: 0,
                    apprenticeCount: 0,
                    projectedSevenDayReviews: 28,
                    timedReviewSampleSize: 40,
                    medianReviewDurationSeconds: 900,
                    projectedDailyReviewMinutes: 60,
                    reviewTimeBudgetMinutes: reviewTimeBudgetMinutes,
                    reviewTimeHeadroomMinutes: reviewTimeHeadroomMinutes,
                    suggestedBatchSize: 5
                )
            ),
            cards: []
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        return try JSONSerialization.data(withJSONObject: ["data": sessionObject])
    }
}
