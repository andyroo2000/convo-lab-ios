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

struct MainModeView: View {
    // Five native slots avoid UIKit's automatic More navigation controller.
    // The four practice/library stacks retain their navigation when switching modes.
    private enum TabSlot: Hashable {
        case study, cards, dailyAudio, readings, manage

        init(_ mode: AppMode) {
            switch mode {
            case .study: self = .study
            case .cards: self = .cards
            case .dailyAudio: self = .dailyAudio
            case .readings: self = .readings
            case .time, .settings: self = .manage
            }
        }

        func mode(management: AppMode) -> AppMode {
            switch self {
            case .study: .study
            case .cards: .cards
            case .dailyAudio: .dailyAudio
            case .readings: .readings
            case .manage: management
            }
        }
    }

    let model: AppModel
    let user: CurrentUser
    @State private var selectedTab: AppMode = .study
    @State private var managementMode: AppMode = .time

    private var slotSelection: Binding<TabSlot> {
        Binding(
            get: { TabSlot(selectedTab) },
            set: { tabSelection.wrappedValue = $0.mode(management: managementMode) }
        )
    }

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
                if newTab == .time || newTab == .settings { managementMode = newTab }
                selectedTab = newTab
            }
        )
    }

    var body: some View {
        TabView(selection: slotSelection) {
            Tab("Study", systemImage: "rectangle.stack.fill", value: TabSlot.study) {
                StudyHomeView(
                    store: model.study,
                    player: model.studyAudioPlayer,
                    timeStore: model.studyTime,
                    automaticSynchronization: model.refreshStudyIfNeeded
                )
                .environment(\.colorScheme, .light)
                .toolbar(.hidden, for: .tabBar)
            }
            Tab("Cards", systemImage: "square.and.pencil", value: TabSlot.cards) {
                CardLibraryView(
                    store: model.study,
                    player: model.studyAudioPlayer,
                    timeStore: model.studyTime
                )
                .environment(\.appModeDestination, .cards)
                .environment(\.colorScheme, .light)
                .toolbar(.hidden, for: .tabBar)
            }
            Tab("Daily Audio", systemImage: "headphones", value: TabSlot.dailyAudio) {
                DailyAudioView(
                    store: model.dailyAudio,
                    player: model.audioPlayer,
                    capabilities: model.study.capabilities.dailyAudio
                )
                .environment(\.colorScheme, .light)
                .toolbar(.hidden, for: .tabBar)
            }
            Tab("Readings", systemImage: "book.closed", value: TabSlot.readings) {
                ReadingLibraryView(api: model.api, userID: user.id) {
                    model.audioPlayer.stop()
                    model.studyAudioPlayer.stop()
                }
                .id("\(user.id):\(model.api.accessToken ?? "")")
                .toolbar(.hidden, for: .tabBar)
            }
            Tab("Manage", systemImage: "gearshape.fill", value: TabSlot.manage) {
                managementContent
                    .environment(\.colorScheme, .light)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .modifier(AppModeHeader(selection: tabSelection))
        .preferredColorScheme(selectedTab == .readings ? nil : .light)
        .tint(ConvoLabTheme.navy)
    }

    @ViewBuilder
    private var managementContent: some View {
        if managementMode == .settings {
            SettingsView(model: model, user: user)
        } else {
            StudyTimeView(store: model.studyTime, studyStore: model.study)
        }
    }
}
