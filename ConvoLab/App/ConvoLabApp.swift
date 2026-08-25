import SwiftUI
import SwiftData

@main
struct ConvoLabApp: App {
    @State private var model: AppModel?
    @Environment(\.scenePhase) private var scenePhase
    private let metricDiagnostics: MetricDiagnosticsSubscriber
#if DEBUG
    private let fixture: UITestFixture?
#endif

    init() {
        let metricDiagnostics = MetricDiagnosticsSubscriber()
        metricDiagnostics.start()
        self.metricDiagnostics = metricDiagnostics
#if DEBUG
        let fixture = UITestFixture.fromProcessArguments()
        self.fixture = fixture
        _model = State(initialValue: fixture == nil ? AppModel() : nil)
#else
        _model = State(initialValue: AppModel())
#endif
    }

    var body: some Scene {
        WindowGroup {
            appContent
        }
    }

    @ViewBuilder
    private var appContent: some View {
#if DEBUG
        if let fixture {
            UITestFixtureView(fixture: fixture)
        } else {
            productionContent
        }
#else
        productionContent
#endif
    }

    @ViewBuilder
    private var productionContent: some View {
        if let model {
            RootView(model: model)
                .modelContainer(model.container)
                .task {
                    await model.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        if model.audioPlayer.isPlaying {
                            NativeDiagnostics.shared.record(
                                .backgroundPlayback,
                                reason: .applicationForegrounded
                            )
                        }
                        Task {
                            await model.applicationDidBecomeActive()
                        }
                    } else {
                        if phase == .background, model.audioPlayer.isPlaying {
                            NativeDiagnostics.shared.record(
                                .backgroundPlayback,
                                reason: .applicationBackgrounded
                            )
                        }
                        model.study.persistCachedState()
                        model.studyTime.stopForegroundAutomaticTracking()
                    }
                }
        }
    }
}
