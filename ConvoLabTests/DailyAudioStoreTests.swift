import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class DailyAudioStoreTests: XCTestCase {
    func makeStore(
        client: APIClient,
        container: ModelContainer,
        diagnostics: NativeDiagnostics = .shared,
        generationPollingInitialDelay: TimeInterval = 5
    ) -> DailyAudioStore {
        DailyAudioStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            ),
            diagnostics: diagnostics,
            generationPollingInitialDelay: generationPollingInitialDelay
        )
    }

    func dailyAudioTrack(updatedAt: Date) -> DailyAudioTrack {
        DailyAudioTrack(
            id: "4aa076b2-1bc7-45a8-b7b4-12b74dcbd463",
            practiceId: "39ac4e14-b8b0-482c-8831-a3c1cb1987e9",
            mode: "drill",
            status: "ready",
            title: "Recognition drill",
            sortOrder: 0,
            audioUrl: "/api/daily-audio-practice/practice/tracks/track/audio",
            approxDurationSeconds: 60,
            updatedAt: updatedAt
        )
    }

    func dailyAudioPractice(
        status: String,
        updatedAt: Date
    ) -> DailyAudioPractice {
        DailyAudioPractice(
            id: "39ac4e14-b8b0-482c-8831-a3c1cb1987e9",
            practiceDate: "2026-07-30",
            status: status,
            targetDurationMinutes: 30,
            errorMessage: nil,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            tracks: []
        )
    }

    func transcriptTrack(timings: [DailyAudioTiming]) -> DailyAudioTrack {
        DailyAudioTrack(
            id: "track",
            practiceId: "practice",
            mode: "drill",
            status: "ready",
            title: "Recognition drill",
            sortOrder: 0,
            scriptUnitsJson: [
                DailyAudioScriptUnit(
                    type: "narration_L1",
                    text: "Listen carefully.",
                    reading: nil,
                    translation: nil
                ),
                DailyAudioScriptUnit(
                    type: "L2",
                    text: "猫です",
                    reading: "猫[ねこ]です",
                    translation: "It is a cat."
                ),
            ],
            audioUrl: "/audio",
            timingData: timings,
            approxDurationSeconds: 2,
            updatedAt: .now
        )
    }

    func insertPractice(
        containing track: DailyAudioTrack,
        userID: Int,
        into container: ModelContainer
    ) throws {
        let practice = DailyAudioPractice(
            id: track.practiceId,
            practiceDate: "2026-07-25",
            status: "ready",
            targetDurationMinutes: 30,
            errorMessage: nil,
            createdAt: .now,
            updatedAt: .now,
            tracks: [track]
        )
        container.mainContext.insert(LocalDailyAudioPractice(
            practice: practice,
            userID: userID,
            payload: try StorageCodec.encoder.encode(practice)
        ))
        try container.mainContext.save()
    }

    func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = handler
        return makeAPIClient()
    }

    func makeDeferredClient(
        handler: @escaping MockURLProtocol.DeferredHandler
    ) -> APIClient {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = handler
        return makeAPIClient()
    }

    private func makeAPIClient() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

}
