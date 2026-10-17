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
            .preferredColorScheme(.light)
        case let .signedIn(user):
            MainModeView(model: model, user: user)
        }
    }
}

private struct MainModeView: View {
    let model: AppModel
    let user: CurrentUser
    @State private var selectedTab: AppMode = .study

    private var tabSelection: Binding<AppMode> {
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
            Tab("Study", systemImage: "rectangle.stack.fill", value: AppMode.study) {
                StudyHomeView(
                    store: model.study,
                    player: model.studyAudioPlayer,
                    timeStore: model.studyTime
                )
                .toolbar(.hidden, for: .tabBar)
            }
            Tab("Cards", systemImage: "square.and.pencil", value: AppMode.cards) {
                CardLibraryView(
                    store: model.study,
                    player: model.studyAudioPlayer,
                    timeStore: model.studyTime
                )
                .toolbar(.hidden, for: .tabBar)
            }
            Tab("Daily Audio", systemImage: "headphones", value: AppMode.dailyAudio) {
                DailyAudioView(
                    store: model.dailyAudio,
                    player: model.audioPlayer,
                    capabilities: model.study.capabilities.dailyAudio
                )
                .toolbar(.hidden, for: .tabBar)
            }
            Tab("Readings", systemImage: "book.closed", value: AppMode.readings) {
                ReadingLibraryView(api: model.api, userID: user.id) {
                    model.audioPlayer.stop()
                    model.studyAudioPlayer.stop()
                }
                .id("\(user.id):\(model.api.accessToken ?? "")")
                .toolbar(.hidden, for: .tabBar)
            }
            Tab("Time", systemImage: "clock.fill", value: AppMode.time) {
                StudyTimeView(store: model.studyTime, studyStore: model.study)
                    .toolbar(.hidden, for: .tabBar)
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppMode.settings) {
                SettingsView(model: model, user: user)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            AppModePicker(selection: tabSelection)
        }
        .preferredColorScheme(selectedTab == .readings ? nil : .light)
        .tint(ConvoLabTheme.navy)
    }
}
