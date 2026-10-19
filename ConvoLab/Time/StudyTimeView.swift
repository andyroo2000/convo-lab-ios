import SwiftUI

enum StudyTimeEditableEntries {
    static let sectionTitle = "Editable entries"
    static let emptyTitle = "No editable entries"
    static let emptyDescription = "Study time you add manually appears here."

    static func filter(_ sessions: [StudyActivitySession]) -> [StudyActivitySession] {
        sessions.filter(\.isEditable)
    }
}
enum StudyTimeManualEntryLoading {
    static func shouldRequestEntries(
        isExpanded: Bool,
        hasRequestedEntries: Bool
    ) -> Bool {
        isExpanded && !hasRequestedEntries
    }
}

enum StudyTimeRangeSelection {
    static func fallback(preferred: StudyTimeRange, analytics: StudyTimeAnalytics?) -> StudyTimeRange? {
        analytics?.range(preferred)?.key ?? analytics?.ranges.first?.key
    }

    static func assign(
        _ target: StudyTimeRange?, selected: inout StudyTimeRange, suppressNextReset: inout Bool
    ) {
        // A same-value assignment does not fire onChange to consume this flag.
        guard let target, target != selected else { return }
        suppressNextReset = true
        selected = target
    }
}

struct StudyTimeView: View {
    let store: StudyTimeStore
    let studyStore: StudyStore
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingEntry = false
    @State private var editingSession: StudyActivitySession?
    @State var selectedRange: StudyTimeRange = .week
    @State var includedCategories = Set(StudyActivityCategory.allCases)
    @State var suppressNextHistoricalRangeReset = false
    @State var analyticsMotion = StudyTimeAnalyticsMotion()
    @State var analyticsCardWidth = CGFloat(360)
    @State var entryErrorMessage: String?
    @State private var isJLPTMasteryExpanded = false
    @State private var isManualTimeEntryExpanded = false
    @State private var hasRequestedEditableSessions = false

    private var selectedAnalytics: StudyTimeAnalyticsRange? {
        store.analytics?.range(selectedRange)
    }

    private var editableSessions: [StudyActivitySession] {
        store.editableSessions
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Time span", selection: $selectedRange) {
                        ForEach(StudyTimeRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Time span")
                    .onChange(of: selectedRange) { previous, _ in
                        cancelAnalyticsNavigation()
                        store.stopAnalyticsPrefetching()
                        if suppressNextHistoricalRangeReset {
                            suppressNextHistoricalRangeReset = false
                            return
                        }
                        // Canonical cached ranges can be selected immediately. A
                        // derived week intentionally has no invented hourly data.
                        let fallback = StudyTimeRangeSelection.fallback(preferred: previous, analytics: store.analytics)
                        scheduleAnalyticsLoad(anchorDate: .now, fallback: fallback)
                    }

                    if let analytics = selectedAnalytics {
                        swipeableAnalytics(analytics)
                    } else {
                        ProgressView("Loading study rhythm…")
                            .frame(maxWidth: .infinity, minHeight: 220)
                    }
                } footer: {
                    Text(
                        "Double-tap a category to filter it out or bring it back. In Week, Month, and Year, "
                            + "double-tap a bar to drill in. Audio drills count as Listen; "
                            + "iTalki and other lessons count as Conversation."
                    )
                }

                Section {
                    WeeklyStudyRecapView(
                        recap: store.weeklyRecap,
                        isLoading: store.weeklyRecapIsLoading,
                        errorMessage: store.weeklyRecapErrorMessage
                    ) {
                        Task { await store.loadWeeklyRecap(force: true) }
                    }
                }

                StudyTimeJLPTMasterySection(
                    mastery: studyStore.overview?.jlptMastery,
                    isLoading: studyStore.isRefreshingOverview,
                    errorMessage: studyStore.overviewRefreshErrorMessage,
                    reduceMotion: reduceMotion,
                    isExpanded: $isJLPTMasteryExpanded
                ) {
                    Task { await studyStore.refreshOverview() }
                }

                if let message = entryErrorMessage
                    ?? store.storageWriteErrorMessage
                    ?? store.syncErrorMessage
                {
                    Section("Sync") {
                        Label(message, systemImage: "exclamationmark.icloud")
                            .foregroundStyle(.red)
                    }
                }

                StudyTimeManualEntrySection(
                    store: store,
                    sessions: editableSessions,
                    reduceMotion: reduceMotion,
                    isExpanded: $isManualTimeEntryExpanded,
                    onAdd: { showingEntry = true },
                    onEdit: { editingSession = $0 },
                    onDelete: delete
                )
            }
            .toolbar(.hidden, for: .navigationBar)
            .onDisappear {
                cancelAnalyticsNavigation()
                store.stopAnalyticsPrefetching()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    store.updateAnalyticsPrefetching(range: selectedRange)
                } else {
                    store.stopAnalyticsPrefetching()
                }
            }
            .sheet(isPresented: $showingEntry) {
                StudyTimeEntryView(store: store)
            }
            .sheet(item: $editingSession) { session in
                StudyTimeEntryView(store: store, session: session)
            }
            .refreshable {
                async let studyTime: Void = store.synchronize()
                async let recap: Void = store.loadWeeklyRecap(force: true)
                async let mastery: Void = studyStore.refreshOverview()
                if isManualTimeEntryExpanded {
                    async let entries: Void = store.loadEditableSessions()
                    _ = await (studyTime, recap, mastery, entries)
                } else {
                    _ = await (studyTime, recap, mastery)
                }
            }
            .task {
                async let recap: Void = store.loadWeeklyRecap()
                async let mastery: Void = studyStore.refreshOverview()
                _ = await (recap, mastery)
            }
            .onChange(of: isManualTimeEntryExpanded) { _, isExpanded in
                guard StudyTimeManualEntryLoading.shouldRequestEntries(
                    isExpanded: isExpanded,
                    hasRequestedEntries: hasRequestedEditableSessions
                ) else { return }
                hasRequestedEditableSessions = true
                Task { await store.loadEditableSessions() }
            }
        }
    }

    private func delete(_ session: StudyActivitySession) {
        entryErrorMessage = nil
        Task {
            do {
                try await store.delete(session: session)
            } catch {
                entryErrorMessage = error.localizedDescription
            }
        }
    }
}
