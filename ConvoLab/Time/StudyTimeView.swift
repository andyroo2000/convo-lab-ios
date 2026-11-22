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
    @State private var tab: StudyTimeTab = .rhythm
    @State private var hasRequestedEditableSessions = false

    private var selectedAnalytics: StudyTimeAnalyticsRange? {
        store.analytics?.range(selectedRange)
    }

    private var editableSessions: [StudyActivitySession] {
        store.editableSessions
    }

    private var visibleError: String? {
        let rhythmShowsRetry = tab == .rhythm && selectedAnalytics == nil
        return entryErrorMessage ?? store.storageWriteErrorMessage ?? (rhythmShowsRetry ? nil : store.syncErrorMessage)
    }

    var body: some View {
        NavigationStack {
            List {
                VStack(spacing: 12) {
                    StudyTimeRecordHeader { showingEntry = true }
                    periodControls
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                Section {
                    StudyTimeRecordTabs(selected: $tab)
                    tabContent
                }
                .listRowBackground(StudyTimePaper.paper)
                .listRowSeparator(.hidden)
                if let message = visibleError {
                    Label(message, systemImage: "exclamationmark.icloud")
                        .foregroundStyle(.red).listRowBackground(StudyTimePaper.paper)
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.horizontal, 14, for: .scrollContent)
            .contentMargins(.top, 16, for: .scrollContent)
            .listSectionSpacing(12)
            .scrollContentBackground(.hidden).background(StudyTimePaper.desk)
            .foregroundStyle(StudyTimePaper.ink)
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
            .outsideDismissibleSheet(isPresented: $showingEntry) {
                StudyTimeEntryView(store: store)
            }
            .outsideDismissibleSheet(item: $editingSession) { session in
                StudyTimeEntryView(store: store, session: session)
            }
            .refreshable {
                async let studyTime: Void = store.synchronize()
                async let recap: Void = store.loadWeeklyRecap(force: true)
                async let mastery: Void = studyStore.refreshOverview()
                if tab == .entries {
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
            .onChange(of: tab) { _, selection in
                guard StudyTimeManualEntryLoading.shouldRequestEntries(
                    isExpanded: selection == .entries,
                    hasRequestedEntries: hasRequestedEditableSessions
                ) else { return }
                hasRequestedEditableSessions = true
                Task { await store.loadEditableSessions() }
            }
        }
    }

    private var periodControls: some View {
        VStack(spacing: 4) {
            StudyTimeRangePicker(selection: $selectedRange)
            .onChange(of: selectedRange) { previous, _ in
                tab = .rhythm
                cancelAnalyticsNavigation()
                store.stopAnalyticsPrefetching()
                if suppressNextHistoricalRangeReset {
                    suppressNextHistoricalRangeReset = false
                    return
                }
                let fallback = StudyTimeRangeSelection.fallback(preferred: previous, analytics: store.analytics)
                scheduleAnalyticsLoad(anchorDate: .now, fallback: fallback)
            }
            if let analytics = selectedAnalytics, selectedRange != .all {
                HStack {
                    periodButton(-1, analytics: analytics)
                    Text(periodLabel(analytics)).font(StudyTimePaper.type(18))
                    periodButton(1, analytics: analytics).disabled(!canNavigateLater(from: analytics))
                }
            }
        }
    }

    private func periodButton(_ direction: Int, analytics: StudyTimeAnalyticsRange) -> some View {
        Button {
            tab = .rhythm
            navigateAnalytics(by: direction, from: analytics)
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.caption).padding(7).background(StudyTimePaper.sage, in: Circle())
                .frame(minWidth: 44, minHeight: 44)
        }.buttonStyle(.plain).accessibilityLabel(direction < 0 ? "Previous period" : "Next period")
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .rhythm:
            if let analytics = selectedAnalytics {
                swipeableAnalytics(analytics)
                Text("Double-tap a category to filter it out or bring it back. In Week, Month, and Year, double-tap a bar to drill in.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if store.syncErrorMessage != nil {
                ContentUnavailableView {
                    Label("Study rhythm unavailable", systemImage: "chart.bar")
                } description: {
                    Text("Your study history couldn’t be loaded.")
                } actions: {
                    Button("Try again") { scheduleAnalyticsLoad(anchorDate: .now) }
                }
            } else {
                ProgressView("Loading study rhythm…").frame(maxWidth: .infinity, minHeight: 220)
            }
        case .recap:
            WeeklyStudyRecapView(recap: store.weeklyRecap, isLoading: store.weeklyRecapIsLoading,
                                 errorMessage: store.weeklyRecapErrorMessage) {
                Task { await store.loadWeeklyRecap(force: true) }
            }
        case .mastery:
            StudyTimeJLPTMasterySection(mastery: studyStore.overview?.jlptMastery,
                                        isLoading: studyStore.isRefreshingOverview,
                                        errorMessage: studyStore.overviewRefreshErrorMessage) {
                Task { await studyStore.refreshOverview() }
            }
        case .entries:
            StudyTimeManualEntrySection(store: store, sessions: editableSessions,
                                       onEdit: { editingSession = $0 }, onDelete: delete)
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
