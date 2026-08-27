import SwiftUI

enum StudyTimeEditableEntries {
    static let sectionTitle = "Editable entries"
    static let emptyTitle = "No editable entries"
    static let emptyDescription = "Timers and manually added study time you can edit appear here."

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

struct StudyTimeView: View {
    let store: StudyTimeStore
    let studyStore: StudyStore
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var showingEntry = false
    @State private var editingSession: StudyActivitySession?
    @State var selectedRange: StudyTimeRange = .week
    @State var includedCategories = Set(StudyActivityCategory.allCases)
    @State var suppressNextHistoricalRangeReset = false
    @State var analyticsDragOffset = CGFloat.zero
    @State var analyticsCardWidth = CGFloat(360)
    @State var isSettlingAnalyticsSwipe = false
    @State var analyticsNavigationGeneration = 0
    @State private var selectedActivity: StudyActivityKind = .cardCreation
    @State private var timerName = ""
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
                    .onChange(of: selectedRange) {
                        analyticsNavigationGeneration += 1
                        isSettlingAnalyticsSwipe = false
                        analyticsDragOffset = 0
                        if suppressNextHistoricalRangeReset {
                            suppressNextHistoricalRangeReset = false
                            return
                        }
                        // A range response already contains every span. Only fetch when a
                        // range switch intentionally returns a historical view to now.
                        guard let anchorDate = store.analytics?.anchorDate,
                              let anchor = analyticsAnchorDate(from: anchorDate),
                              !Calendar.current.isDateInToday(anchor)
                        else {
                            return
                        }
                        Task { await store.loadAnalytics(anchorDate: .now) }
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
                    selectedActivity: $selectedActivity,
                    timerName: $timerName,
                    onEdit: { editingSession = $0 },
                    onDelete: delete
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingEntry = true
                    } label: {
                        Label("Add time", systemImage: "calendar.badge.plus")
                    }
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
