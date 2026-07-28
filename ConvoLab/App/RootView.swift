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
    private enum MainTab: Hashable {
        case study
        case cards
        case dailyAudio
        case time
        case settings
    }

    let model: AppModel
    let user: CurrentUser
    @State private var selectedTab: MainTab = .study

    private var tabSelection: Binding<MainTab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                guard newTab != selectedTab else { return }
                if selectedTab == .study || selectedTab == .cards,
                   let active = model.studyTime.active,
                   active.source == .automatic,
                   active.activity == .cardReview || active.activity == .cardCreation
                {
                    model.studyTime.stop(
                        activity: active.activity,
                        source: .automatic
                    )
                }
                selectedTab = newTab
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("Study", systemImage: "rectangle.stack.fill", value: MainTab.study) {
                StudyHomeView(
                    store: model.study,
                    player: model.studyAudioPlayer,
                    timeStore: model.studyTime
                )
            }
            Tab("Cards", systemImage: "square.and.pencil", value: MainTab.cards) {
                CardLibraryView(
                    store: model.study,
                    player: model.studyAudioPlayer,
                    timeStore: model.studyTime
                )
            }
            Tab("Daily Audio", systemImage: "headphones", value: MainTab.dailyAudio) {
                DailyAudioView(store: model.dailyAudio, player: model.audioPlayer)
            }
            Tab("Time", systemImage: "clock.fill", value: MainTab.time) {
                StudyTimeView(store: model.studyTime)
            }
            Tab("Settings", systemImage: "gearshape.fill", value: MainTab.settings) {
                SettingsView(model: model, user: user)
            }
        }
        .tint(ConvoLabTheme.navy)
    }
}
