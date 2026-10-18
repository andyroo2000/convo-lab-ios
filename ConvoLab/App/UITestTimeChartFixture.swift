#if DEBUG
import SwiftUI

/// Real Time view, stores and HTTP decoding with deterministic history. The small
/// measurement footer exists only in this explicitly requested UI-test fixture.
struct UITestTimeChartFixture: View {
    @State private var model: AppModel
    @State private var result = "idle"
    @State private var probe = TimeChartFixtureProbe()
    private let history = TimeChartFixtureHistory.shared

    init() {
        let baseURL = URL(string: "https://time-chart.ui-tests.invalid")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimeChartFixtureProtocol.self]
        let api = APIClient(baseURL: baseURL, session: URLSession(configuration: configuration))
        let model = AppModel(
            configuration: .init(apiBaseURL: baseURL),
            makeContainer: { _ in try Persistence.makeContainer(inMemory: true) },
            makeStudyTimeContainer: { _ in try StudyTimePersistence.makeContainer(inMemory: true) },
            makeAPIClient: { _ in api },
            makeAuthStore: { AuthStore(api: $0, keychain: TimeChartFixtureCredentials()) },
            makeAudioPlayer: { AudioPlayer(deterministicUITestBackend: ()) }
        )
        model.study.activate(userID: -208)
        model.studyTime.activate(userID: -208)
        _model = State(initialValue: model)
    }

    var body: some View {
        StudyTimeView(store: model.studyTime, studyStore: model.study)
            .safeAreaInset(edge: .bottom, spacing: 0) { measurementControls }
            .task { _ = await model.studyTime.loadAnalytics(anchorDate: history.now) }
            .preferredColorScheme(.light)
    }

    private var measurementControls: some View {
        VStack(spacing: 4) {
            Text(model.studyTime.analytics?.anchorDate ?? "loading")
                .accessibilityIdentifier("TimeChartFixtureAnchor")
                .accessibilityValue(expectedTotals)
            HStack {
                Button("Start measurement") {
                    result = "running"
                    probe.start()
                }
                Button("Stop measurement") { result = probe.finish() }
                Button("Uncached") { Task { await loadUncachedWeek() } }
            }
            Text("Metrics")
                .accessibilityValue(result)
                .accessibilityIdentifier("TimeChartFixtureMetrics")
        }
        .font(.caption)
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.regularMaterial)
    }

    private var expectedTotals: String {
        guard let week = model.studyTime.analytics?.range(.week) else { return "" }
        return [
            studyTimeCompactDuration(week.totalMs),
            studyTimeCompactDuration(week.totalMs - week.duration(for: .review)),
        ].joined(separator: "|")
    }

    private func loadUncachedWeek() async {
        let anchor = history.calendar.date(byAdding: .day, value: -21, to: history.now)!
        let previous = history.calendar.date(byAdding: .day, value: -28, to: history.now)!
        TimeChartFixtureProtocol.delay(anchor: history.anchor(previous))
        _ = await model.studyTime.loadAnalytics(anchorDate: anchor)
    }
}

private struct TimeChartFixtureCredentials: CredentialStore {
    func save(_ value: String, account: String) throws {}
    func read(account: String) throws -> String? { nil }
    func remove(account: String) throws {}
}
#endif
