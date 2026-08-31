import XCTest
@testable import ConvoLab

@MainActor
final class StudyCapabilitiesTests: XCTestCase {
    func testDecodesAuthoritativeCapabilityContractAndPreservesUnknownIdentifiers() throws {
        let capabilities = try JSONDecoder().decode(
            StudyCapabilities.self,
            from: capabilityData
        )

        XCTAssertEqual(capabilities.version, 2)
        XCTAssertEqual(capabilities.settings.lessonBatchSize.range, 4...8)
        XCTAssertEqual(capabilities.cardAuthoring.limits.imagePromptCharacters, 321)
        XCTAssertEqual(capabilities.cardAuthoring.creationKinds.last, "future-kind")
        XCTAssertEqual(capabilities.offlineReserve.days, 7)
    }

    func testSettingsValidationUsesAdvertisedRanges() throws {
        let fallback = StudyCapabilities.fallback
        let capabilities = StudyCapabilities(
            version: fallback.version,
            settings: .init(
                newCardsPerDay: .init(default: 12, min: 10, max: 20),
                lessonBatchSize: .init(default: 6, min: 4, max: 8),
                reviewTimeBudgetMinutes: .init(default: 60, min: 30, max: 120),
                newCardLaneWeights: .init(
                    standard: .init(default: 2, min: 2, max: 5),
                    lessonFollowup: .init(default: 1, min: 1, max: 4),
                    wanikani: .init(default: 0, min: 0, max: 3)
                )
            ),
            cardAuthoring: fallback.cardAuthoring,
            dailyAudio: fallback.dailyAudio,
            offlineReserve: fallback.offlineReserve,
            imports: fallback.imports
        )

        XCTAssertTrue(StudySettingsPolicy.accepts(
            newCardsPerDay: 10,
            lessonBatchSize: 8,
            reviewTimeBudgetMinutes: 120,
            newCardLaneWeights: .init(standard: 2, lessonFollowup: 1, wanikani: 3),
            capabilities: capabilities
        ))
        XCTAssertFalse(StudySettingsPolicy.accepts(
            newCardsPerDay: 9,
            lessonBatchSize: 8,
            reviewTimeBudgetMinutes: 120,
            capabilities: capabilities
        ))
    }

    func testStoreRefreshesCapabilitiesFromDedicatedEndpoint() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let responseData = capabilityData
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/study/capabilities")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                responseData
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )

        await store.refreshCapabilities()

        XCTAssertEqual(store.capabilities.version, 2)
        XCTAssertEqual(store.capabilities.cardAuthoring.limits.imagePromptCharacters, 321)
    }

    private var capabilityData: Data {
        Data(
            #"{"version":2,"settings":{"newCardsPerDay":{"default":12,"min":1,"max":40},"lessonBatchSize":{"default":6,"min":4,"max":8},"reviewTimeBudgetMinutes":{"default":75,"min":30,"max":180},"newCardLaneWeights":{"standard":{"default":4,"min":2,"max":12},"lessonFollowup":{"default":2,"min":1,"max":9},"wanikani":{"default":1,"min":0,"max":7}}},"cardAuthoring":{"creationKinds":["text-recognition","future-kind"],"imagePlacements":["none","future-place"],"previewAudioRoles":["prompt","future-role"],"defaultAnswerAudioVoiceId":"voice-default","defaultFemaleAnswerAudioVoiceId":"voice-female","limits":{"combinedPayloadBytes":12000,"payloadDepth":6,"imagePromptCharacters":321,"imageUploadBytes":456000}},"dailyAudio":{"targetDurationMinutes":{"default":25,"min":10,"max":50}},"offlineReserve":{"days":7,"maxScheduledCards":777},"imports":{"maxArchiveBytes":999999}}"#.utf8
        )
    }
}
