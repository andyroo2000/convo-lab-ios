import SwiftUI

struct RootView: View {
    let model: AppModel

    var body: some View {
        switch model.auth.state {
        case .restoring:
            ProgressView("Opening ConvoLab…")
                .paperBackground()
        case .signedOut:
            LoginView(auth: model.auth) {
                await model.synchronize()
            }
        case let .signedIn(user):
            MainTabView(model: model, user: user)
        }
    }
}

private struct MainTabView: View {
    let model: AppModel
    let user: CurrentUser

    var body: some View {
        TabView {
            Tab("Study", systemImage: "rectangle.stack.fill") {
                StudyHomeView(
                    store: model.study,
                    player: model.studyAudioPlayer
                )
            }
            Tab("Cards", systemImage: "square.and.pencil") {
                CardLibraryView(store: model.study)
            }
            Tab("Daily Audio", systemImage: "headphones") {
                DailyAudioView(store: model.dailyAudio, player: model.audioPlayer)
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView(model: model, user: user)
            }
        }
        .tint(ConvoLabTheme.navy)
    }
}
