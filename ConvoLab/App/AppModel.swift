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
    let isUsingEphemeralStorage: Bool

    init(configuration: AppConfiguration = .load()) {
        let container: ModelContainer
        do {
            container = try Persistence.makeContainer()
            isUsingEphemeralStorage = false
        } catch {
            do {
                // Keep the app usable if a future schema change makes the on-disk store
                // unreadable. Server-backed data can still sync while the store is repaired.
                container = try Persistence.makeContainer(inMemory: true)
                isUsingEphemeralStorage = true
            } catch {
                fatalError("Unable to initialize persistent or recovery storage: \(error)")
            }
        }
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
        await refreshAuthenticatedData()
    }

    func synchronize() async {
        await auth.restore()
        guard case .signedIn = auth.state else { return }
        await refreshAuthenticatedData()
    }

    private func refreshAuthenticatedData() async {
        async let studySync: Void = study.synchronize()
        async let audioRefresh: Void = dailyAudio.refresh()
        _ = await (studySync, audioRefresh)
    }
}
