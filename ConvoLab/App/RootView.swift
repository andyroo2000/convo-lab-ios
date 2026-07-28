import SwiftUI

struct RootView: View {
    let model: AppModel

    var body: some View {
        switch model.auth.state {
        case .restoring:
            ZStack {
                ConvoLabTheme.cream
                    .ignoresSafeArea()

                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(ConvoLabTheme.cyan.opacity(0.16))
                            .frame(width: 88, height: 88)
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(ConvoLabTheme.navy)
                    }
                    Text("CONVOLAB")
                        .font(.title2.bold())
                        .tracking(3)
                        .foregroundStyle(ConvoLabTheme.navy)
                    Text("Preparing your study space")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ProgressView()
                        .tint(ConvoLabTheme.coral)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Opening ConvoLab")
            }
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
                CardLibraryView(
                    store: model.study,
                    player: model.studyAudioPlayer
                )
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
