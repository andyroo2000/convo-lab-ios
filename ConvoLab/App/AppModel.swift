import Foundation
import SwiftData

@Observable
final class AppModel {
    let container: ModelContainer
    let api: APIClient
    let auth: AuthStore
    let mediaCache: MediaCache
    let study: StudyStore
    let dailyAudio: DailyAudioStore
    let audioPlayer: AudioPlayer

    init(configuration: AppConfiguration = .load()) {
        let container = try! Persistence.makeContainer()
        let api = APIClient(baseURL: configuration.apiBaseURL)
        let mediaCache = MediaCache(api: api, context: container.mainContext)

        self.container = container
        self.api = api
        auth = AuthStore(api: api)
        self.mediaCache = mediaCache
        study = StudyStore(api: api, context: container.mainContext, mediaCache: mediaCache)
        dailyAudio = DailyAudioStore(
            api: api,
            context: container.mainContext,
            mediaCache: mediaCache
        )
        audioPlayer = AudioPlayer()
    }

    func start() async {
        await auth.restore()
        guard case .signedIn = auth.state else { return }
        async let studySync: Void = study.synchronize()
        async let audioRefresh: Void = dailyAudio.refresh()
        _ = await (studySync, audioRefresh)
    }
}

