import SwiftUI

struct RootView: View {
    let model: AppModel

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if let message = model.storageStatus.warningMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(ConvoLabTheme.navy)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.orange.opacity(0.22))
                            .accessibilityIdentifier("degraded-storage-warning")
                            .accessibilityLabel(message)
                    }
                    if model.shouldShowAccountDeletionCleanupWarning {
                        accountDeletionCleanupWarning
                    }
                }
            }
    }

    private var accountDeletionCleanupWarning: some View {
        HStack(alignment: .center, spacing: 12) {
            Label(
                "Some local data from a deleted account still needs to be removed from this device.",
                systemImage: "hand.raised.fill"
            )
            .font(.footnote.weight(.semibold))
            .foregroundStyle(ConvoLabTheme.navy)
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.isRetryingAccountDeletionCleanup {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Retry") {
                    Task { await model.retryAccountDeletionCleanup() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(ConvoLabTheme.navy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.22))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-deletion-cleanup-warning")
    }

    @ViewBuilder
    private var content: some View {
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
