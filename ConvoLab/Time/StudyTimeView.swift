import Charts
import SwiftUI
import UIKit

enum StudyTimeSwipeRecognition {
    enum Navigation: Equatable {
        case previous
        case next
        case snapBack
    }

    static func isHorizontal(translation: CGPoint) -> Bool {
        abs(translation.x) > abs(translation.y)
    }

    static func navigation(
        translation: CGPoint,
        projectedTranslationX: CGFloat,
        canNavigateLater: Bool
    ) -> Navigation {
        guard isHorizontal(translation: translation) else { return .snapBack }
        if max(translation.x, projectedTranslationX) > 70 {
            return .previous
        }
        if min(translation.x, projectedTranslationX) < -70, canNavigateLater {
            return .next
        }
        return .snapBack
    }
}

private struct HorizontalStudyTimePanGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (_ translation: CGPoint, _ projectedTranslationX: CGFloat) -> Void
    let onCancelled: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var configuration: HorizontalStudyTimePanGesture

        init(configuration: HorizontalStudyTimePanGesture) {
            self.configuration = configuration
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard configuration.isEnabled,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer
            else {
                return false
            }
            return StudyTimeSwipeRecognition.isHorizontal(
                translation: pan.translation(in: pan.view)
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(configuration: self)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.cancelsTouchesInView = false
        recognizer.maximumNumberOfTouches = 1
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(
        _ recognizer: UIPanGestureRecognizer,
        context: Context
    ) {
        context.coordinator.configuration = self
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UIPanGestureRecognizer,
        context: Context
    ) {
        let configuration = context.coordinator.configuration
        let translation = recognizer.translation(in: recognizer.view)
        switch recognizer.state {
        case .began, .changed:
            configuration.onChanged(translation.x)
        case .ended:
            let velocity = recognizer.velocity(in: recognizer.view).x
            configuration.onEnded(translation, translation.x + velocity * 0.2)
        case .cancelled, .failed:
            configuration.onCancelled()
        default:
            break
        }
    }
}

enum StudyTimeEditableEntries {
    static let sectionTitle = "Editable entries"
    static let emptyTitle = "No editable entries"
    static let emptyDescription = "Timers and manually added study time you can edit appear here."

    static func filter(_ sessions: [StudyActivitySession]) -> [StudyActivitySession] {
        sessions.filter(\.isEditable)
    }
}

struct StudyTimeView: View {
    let store: StudyTimeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingEntry = false
    @State private var editingSession: StudyActivitySession?
    @State private var selectedRange: StudyTimeRange = .week
    @State private var includedCategories = Set(StudyActivityCategory.allCases)
    @State private var suppressNextHistoricalRangeReset = false
    @State private var analyticsDragOffset = CGFloat.zero
    @State private var analyticsCardWidth = CGFloat(360)
    @State private var isSettlingAnalyticsSwipe = false
    @State private var analyticsNavigationGeneration = 0
    @State private var selectedActivity: StudyActivityKind = .cardCreation
    @State private var timerName = ""
    @State private var entryErrorMessage: String?

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
                } header: {
                    Text("Study Rhythm")
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

                Section("Timer") {
                    Picker("Activity", selection: $selectedActivity) {
                        ForEach([
                            StudyActivityKind.cardCreation,
                            .tv,
                            .podcast,
                            .reading,
                            .conversation,
                            .wanikaniReview,
                            .other,
                        ]) { activity in
                            Text(activity.title).tag(activity)
                        }
                    }
                    TextField("Source, show, or project (optional)", text: $timerName)
                    if let active = store.active {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(active.name ?? active.activity.title)
                                        .font(.headline)
                                    Text(
                                        Duration.seconds(
                                            context.date.timeIntervalSince(active.startedAt)
                                        ),
                                        format: .time(pattern: .hourMinuteSecond)
                                    )
                                    .monospacedDigit()
                                    .accessibilityHidden(true)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(active.name ?? active.activity.title)
                                .accessibilityValue("Timer running")
                                Spacer()
                                Button("Stop", role: .destructive) { store.stop() }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    } else {
                        Button {
                            store.start(
                                activity: selectedActivity,
                                source: .manual,
                                name: timerName.nilIfBlank
                            )
                        } label: {
                            Label("Start session", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ConvoLabTheme.navy)
                    }
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

                Section(StudyTimeEditableEntries.sectionTitle) {
                    if store.editableSessionsIsLoading, editableSessions.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView("Loading entries…")
                            Spacer()
                        }
                    } else if let message = store.editableSessionsErrorMessage,
                              editableSessions.isEmpty
                    {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Button("Retry") {
                                Task { await store.loadEditableSessions() }
                            }
                        }
                    } else if editableSessions.isEmpty {
                        ContentUnavailableView(
                            StudyTimeEditableEntries.emptyTitle,
                            systemImage: "clock.badge",
                            description: Text(StudyTimeEditableEntries.emptyDescription)
                        )
                    }
                    ForEach(editableSessions, id: \.stableID) { session in
                        StudyTimeSessionRow(session: session)
                            .contentShape(Rectangle())
                            .onTapGesture { editingSession = session }
                            .swipeActions(allowsFullSwipe: false) {
                                Button("Delete", role: .destructive) {
                                    delete(session)
                                }
                                Button("Edit") {
                                    editingSession = session
                                }
                                .tint(ConvoLabTheme.navy)
                            }
                    }
                    if store.editableSessionsNextCursor != nil {
                        Button {
                            Task { await store.loadEditableSessions(reset: false) }
                        } label: {
                            HStack {
                                Spacer()
                                if store.editableSessionsIsLoading {
                                    ProgressView()
                                    Text("Loading…")
                                } else {
                                    Text("Load more entries")
                                }
                                Spacer()
                            }
                            .frame(minHeight: 44)
                        }
                        .disabled(store.editableSessionsIsLoading)
                    }
                }
            }
            .navigationTitle("Study Time")
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
                async let entries: Void = store.loadEditableSessions()
                _ = await (studyTime, recap, entries)
            }
            .task {
                async let recap: Void = store.loadWeeklyRecap()
                async let entries: Void = store.loadEditableSessions()
                _ = await (recap, entries)
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

    private func swipeableAnalytics(
        _ analytics: StudyTimeAnalyticsRange
    ) -> some View {
        let dragOffset = displayedAnalyticsDragOffset(analytics)
        return ZStack {
            if let previous = adjacentAnalytics(by: -1) {
                analyticsPage(previous.range, generatedAt: previous.generatedAt)
                    .offset(x: -analyticsCardWidth + dragOffset)
                    .accessibilityHidden(true)
            }

            analyticsPage(
                analytics,
                generatedAt: store.analytics?.generatedAt ?? .now
            )
            .offset(x: dragOffset)

            if canNavigateLater(from: analytics),
               let next = adjacentAnalytics(by: 1)
            {
                analyticsPage(next.range, generatedAt: next.generatedAt)
                    .offset(x: analyticsCardWidth + dragOffset)
                    .accessibilityHidden(true)
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        analyticsCardWidth = max(geometry.size.width, 1)
                    }
                    .onChange(of: geometry.size.width) { _, width in
                        analyticsCardWidth = max(width, 1)
                    }
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            HorizontalStudyTimePanGesture(
                isEnabled: selectedRange != .all && !isSettlingAnalyticsSwipe,
                onChanged: { analyticsDragOffset = $0 },
                onEnded: { translation, projectedTranslationX in
                    finishAnalyticsPan(
                        translation: translation,
                        projectedTranslationX: projectedTranslationX,
                        analytics: analytics
                    )
                },
                onCancelled: snapAnalyticsBack
            )
        )
        .task(
            id: "\(store.analytics?.anchorDate ?? "")"
                + "-\(selectedRange.rawValue)-\(store.analyticsCacheGeneration)"
        ) {
            await prefetchAdjacentAnalytics(from: analytics)
        }
        .accessibilityActions {
            if selectedRange != .all {
                Button("Previous period") {
                    navigateAnalytics(by: -1, from: analytics)
                }
                if canNavigateLater(from: analytics) {
                    Button("Next period") {
                        navigateAnalytics(by: 1, from: analytics)
                    }
                }
            }
        }
    }

    private func analyticsPage(
        _ analytics: StudyTimeAnalyticsRange,
        generatedAt: Date
    ) -> some View {
        let drillDownAction: ((StudyTimeAnalyticsBucket) -> Void)? =
            if analytics.key.drillDownTarget == nil {
                nil
            } else {
                { bucket in drillDown(bucket) }
            }

        return VStack(alignment: .leading, spacing: 8) {
            if selectedRange != .all {
                Text(periodLabel(analytics))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            StudyRhythmChart(
                analytics: analytics,
                generatedAt: generatedAt,
                includedCategories: includedCategories,
                onToggleCategory: toggleCategory,
                onDrillDown: drillDownAction
            )
        }
    }

    private func toggleCategory(_ category: StudyActivityCategory) {
        guard !includedCategories.contains(category) || includedCategories.count > 1 else {
            return
        }
        if includedCategories.contains(category) {
            includedCategories.remove(category)
        } else {
            includedCategories.insert(category)
        }
    }

    private func drillDown(_ bucket: StudyTimeAnalyticsBucket) {
        guard let nextRange = selectedRange.drillDownTarget else { return }
        analyticsNavigationGeneration += 1
        let navigationGeneration = analyticsNavigationGeneration
        isSettlingAnalyticsSwipe = false
        analyticsDragOffset = 0

        Task {
            guard await store.loadAnalytics(anchorDate: bucket.startsAt) else { return }
            guard analyticsNavigationGeneration == navigationGeneration else { return }
            suppressNextHistoricalRangeReset = true
            selectedRange = nextRange
        }
    }

    private func adjacentAnalytics(
        by amount: Int
    ) -> (range: StudyTimeAnalyticsRange, generatedAt: Date)? {
        guard let anchor = shiftedAnalyticsAnchor(by: amount),
              let cached = store.cachedAnalytics(anchorDate: anchor),
              let range = cached.range(selectedRange)
        else {
            return nil
        }
        return (range, cached.generatedAt)
    }

    private func prefetchAdjacentAnalytics(
        from analytics: StudyTimeAnalyticsRange
    ) async {
        guard selectedRange != .all else { return }
        if let previousAnchor = shiftedAnalyticsAnchor(by: -1) {
            _ = await store.prefetchAnalytics(anchorDate: previousAnchor)
        }
        if canNavigateLater(from: analytics),
           let nextAnchor = shiftedAnalyticsAnchor(by: 1)
        {
            _ = await store.prefetchAnalytics(anchorDate: nextAnchor)
        }
    }

    private func displayedAnalyticsDragOffset(
        _ analytics: StudyTimeAnalyticsRange
    ) -> CGFloat {
        if analyticsDragOffset < 0, !canNavigateLater(from: analytics) {
            return rubberBand(analyticsDragOffset)
        }
        return analyticsDragOffset
    }

    private func finishAnalyticsPan(
        translation: CGPoint,
        projectedTranslationX: CGFloat,
        analytics: StudyTimeAnalyticsRange
    ) {
        guard selectedRange != .all, !isSettlingAnalyticsSwipe else { return }
        switch StudyTimeSwipeRecognition.navigation(
            translation: translation,
            projectedTranslationX: projectedTranslationX,
            canNavigateLater: canNavigateLater(from: analytics)
        ) {
        case .previous:
            completeAnalyticsSwipe(by: -1)
        case .next:
            completeAnalyticsSwipe(by: 1)
        case .snapBack:
            snapAnalyticsBack()
        }
    }

    private func navigateAnalytics(
        by amount: Int,
        from analytics: StudyTimeAnalyticsRange
    ) {
        guard selectedRange != .all else { return }
        if amount > 0, !canNavigateLater(from: analytics) { return }
        completeAnalyticsSwipe(by: amount)
    }

    private func completeAnalyticsSwipe(by amount: Int) {
        guard !isSettlingAnalyticsSwipe,
              let nextAnchor = shiftedAnalyticsAnchor(by: amount)
        else {
            return
        }

        isSettlingAnalyticsSwipe = true
        analyticsNavigationGeneration += 1
        let navigationGeneration = analyticsNavigationGeneration
        let outgoingOffset = amount < 0 ? analyticsCardWidth : -analyticsCardWidth

        Task {
            var ready = store.cachedAnalytics(anchorDate: nextAnchor) != nil
            if !ready {
                ready = await store.prefetchAnalytics(
                    anchorDate: nextAnchor,
                    reportFailure: true
                )
            }
            guard analyticsNavigationGeneration == navigationGeneration else { return }
            guard ready else {
                snapAnalyticsBack()
                isSettlingAnalyticsSwipe = false
                return
            }

            if reduceMotion {
                _ = store.selectCachedAnalytics(anchorDate: nextAnchor)
                analyticsDragOffset = 0
                isSettlingAnalyticsSwipe = false
                return
            }

            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.9)) {
                analyticsDragOffset = outgoingOffset
            } completion: {
                guard analyticsNavigationGeneration == navigationGeneration else {
                    return
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    let selected = store.selectCachedAnalytics(anchorDate: nextAnchor)
                    if !selected {
                        entryErrorMessage =
                            "Study time changed while navigating. Swipe again to reload."
                    }
                    analyticsDragOffset = 0
                    isSettlingAnalyticsSwipe = false
                }
            }
        }
    }

    private func snapAnalyticsBack() {
        guard analyticsDragOffset != 0 else { return }
        if reduceMotion {
            analyticsDragOffset = 0
        } else {
            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.72)) {
                analyticsDragOffset = 0
            }
        }
    }

    private func shiftedAnalyticsAnchor(by amount: Int) -> Date? {
        let calendar = Calendar.current
        guard let anchorDate = store.analytics?.anchorDate,
              let analyticsAnchor = analyticsAnchorDate(from: anchorDate)
        else {
            return nil
        }
        switch selectedRange {
        case .today:
            return calendar.date(byAdding: .day, value: amount, to: analyticsAnchor)
        case .week:
            return calendar.date(byAdding: .day, value: amount * 7, to: analyticsAnchor)
        case .month:
            guard let start = calendar.dateInterval(of: .month, for: analyticsAnchor)?.start else {
                return nil
            }
            return calendar.date(byAdding: .month, value: amount, to: start)
        case .year:
            guard let start = calendar.dateInterval(of: .year, for: analyticsAnchor)?.start else {
                return nil
            }
            return calendar.date(byAdding: .year, value: amount, to: start)
        case .all:
            return nil
        }
    }

    private func canNavigateLater(from analytics: StudyTimeAnalyticsRange) -> Bool {
        guard selectedRange != .all, let generatedAt = store.analytics?.generatedAt else {
            return false
        }
        return analytics.endsAt <= generatedAt
    }

    private func periodLabel(_ analytics: StudyTimeAnalyticsRange) -> String {
        let inclusiveEnd = analytics.endsAt.addingTimeInterval(-1)
        switch analytics.key {
        case .today:
            return analytics.startsAt.formatted(
                .dateTime.weekday(.wide).month(.wide).day().year()
            )
        case .week:
            return "\(analytics.startsAt.formatted(.dateTime.month(.abbreviated).day()))"
                + " – "
                + inclusiveEnd.formatted(.dateTime.month(.abbreviated).day().year())
        case .month:
            return analytics.startsAt.formatted(.dateTime.month(.wide).year())
        case .year:
            return analytics.startsAt.formatted(.dateTime.year())
        case .all:
            return ""
        }
    }

    private func rubberBand(_ offset: CGFloat) -> CGFloat {
        let magnitude = abs(offset)
        return copysign(42 * (1 - exp(-magnitude / 110)), offset)
    }

    private func analyticsAnchorDate(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}

private struct StudyRhythmChart: View {
    let analytics: StudyTimeAnalyticsRange
    let generatedAt: Date
    let includedCategories: Set<StudyActivityCategory>
    let onToggleCategory: (StudyActivityCategory) -> Void
    let onDrillDown: ((StudyTimeAnalyticsBucket) -> Void)?

    private var projection: StudyTimeAnalyticsProjection {
        StudyTimeAnalyticsProjection(
            analytics: analytics,
            generatedAt: generatedAt,
            includedCategories: includedCategories
        )
    }

    private var axisDates: [Date] {
        let step = switch analytics.key {
        case .today: 4
        case .month: 5
        default: 1
        }
        let lastIndex = analytics.buckets.count - 1

        return analytics.buckets.enumerated().compactMap { index, bucket in
            index.isMultiple(of: step) || index == lastIndex ? bucket.startsAt : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                metric("Total", milliseconds: projection.totalDurationMs)
                metric("Daily avg", milliseconds: projection.dailyAverageDurationMs)
                VStack(spacing: 4) {
                    Text("Best")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(projection.bestBucket.map(bestBucketLabel) ?? "—")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(
                        "\(compactDuration(projection.bestBucketDurationMs)) total"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }

            analyticsChart
                .frame(height: 210)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(StudyActivityCategory.allCases) { category in
                    legendItem(category)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var analyticsChart: some View {
        Chart {
            ForEach(analytics.buckets) { bucket in
                ForEach(projection.includedCategoryList) { category in
                    let milliseconds = bucket.duration(for: category)
                    if milliseconds > 0 {
                        BarMark(
                            x: .value("Period", bucket.startsAt),
                            y: .value("Minutes", Double(milliseconds) / 60_000)
                        )
                        .foregroundStyle(by: .value("Category", category.title))
                    }
                }
            }
        }
            .chartForegroundStyleScale(
                domain: projection.includedCategoryList.map(\.title),
                range: projection.includedCategoryList.map(\.chartColor)
            )
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) {
                            Text(axisDuration(minutes))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: axisDates) { value in
                    AxisGridLine()
                    if let date = value.as(Date.self) {
                        AxisValueLabel {
                            Text(axisLabel(date))
                        }
                    }
                }
            }
            .chartXScale(
                domain: projection.chartDomain,
                range: .plotDimension(padding: 12)
            )
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                        .simultaneousGesture(
                            SpatialTapGesture(count: 2)
                                .onEnded { value in
                                    handleChartDoubleTap(
                                        at: value.location,
                                        proxy: proxy,
                                        geometry: geometry
                                    )
                                }
                        )
                }
            }
            .accessibilityRepresentation {
                VStack {
                    ForEach(analytics.buckets) { bucket in
                        bucketAccessibilityElement(bucket)
                    }
                }
            }
    }

    @ViewBuilder
    private func bucketAccessibilityElement(
        _ bucket: StudyTimeAnalyticsBucket
    ) -> some View {
        if let onDrillDown {
            Button(bestBucketLabel(bucket)) {
                onDrillDown(bucket)
            }
            .accessibilityLabel(bucketAccessibilityLabel(bucket))
            .accessibilityValue(compactDuration(projection.duration(for: bucket)))
            .accessibilityHint("Double-tap to open this period")
        } else {
            Text(bestBucketLabel(bucket))
                .accessibilityLabel(bucketAccessibilityLabel(bucket))
                .accessibilityValue(compactDuration(projection.duration(for: bucket)))
        }
    }

    private func bucketAccessibilityLabel(
        _ bucket: StudyTimeAnalyticsBucket
    ) -> String {
        let categorySummary = projection.includedCategoryList.compactMap { category in
            let duration = bucket.duration(for: category)
            return duration > 0 ? "\(category.title) \(compactDuration(duration))" : nil
        }
        return ([bestBucketLabel(bucket)] + categorySummary).joined(separator: ", ")
    }

    private func handleChartDoubleTap(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let onDrillDown,
              let plotFrame = proxy.plotFrame
        else {
            return
        }
        let frame = geometry[plotFrame]
        let xPosition = location.x - frame.minX
        guard xPosition >= 0,
              xPosition <= frame.width,
              let date: Date = proxy.value(atX: xPosition),
              let bucket = analytics.buckets.first(where: {
                  date >= $0.startsAt && date < $0.endsAt
              })
        else {
            return
        }
        onDrillDown(bucket)
    }

    private func legendItem(_ category: StudyActivityCategory) -> some View {
        let included = includedCategories.contains(category)
        let isOnlyIncludedCategory = included && includedCategories.count == 1

        return HStack(spacing: 8) {
            Circle()
                .fill(category.chartColor)
                .frame(width: 10, height: 10)
            Text(category.title)
            Spacer(minLength: 2)
            Text(compactDuration(projection.duration(for: category)))
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(included ? Color.primary : Color.secondary)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(
            included
                ? Color(uiColor: .secondarySystemBackground)
                : Color.secondary.opacity(0.08),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(
                    included ? category.chartColor : Color.secondary.opacity(0.2),
                    lineWidth: included ? 2 : 1
                )
        }
        .opacity(included ? 1 : 0.62)
        .contentShape(Capsule())
        .onTapGesture(count: 2) {
            guard !isOnlyIncludedCategory else { return }
            onToggleCategory(category)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(category.title)
        .accessibilityValue(
            "\(compactDuration(projection.duration(for: category))), "
                + (included ? "included" : "filtered out")
        )
        .accessibilityHint("Double-tap to toggle this category")
        .accessibilityAction {
            guard !isOnlyIncludedCategory else { return }
            onToggleCategory(category)
        }
    }

    private func axisLabel(_ date: Date) -> String {
        switch analytics.key {
        case .today:
            date.formatted(.dateTime.hour())
        case .week:
            date.formatted(.dateTime.weekday(.narrow))
        case .month:
            date.formatted(.dateTime.day())
        case .year:
            date.formatted(.dateTime.month(.narrow))
        case .all:
            date.formatted(.dateTime.year())
        }
    }

    private func metric(_ title: String, milliseconds: Int) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(compactDuration(milliseconds))
                .font(.headline)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private func bestBucketLabel(_ bucket: StudyTimeAnalyticsBucket) -> String {
        switch analytics.key {
        case .today:
            bucket.startsAt.formatted(.dateTime.hour())
        case .week:
            bucket.startsAt.formatted(.dateTime.weekday(.abbreviated))
        case .month:
            bucket.startsAt.formatted(.dateTime.day())
        case .year:
            bucket.startsAt.formatted(.dateTime.month(.abbreviated))
        case .all:
            bucket.startsAt.formatted(.dateTime.year())
        }
    }

    private func axisDuration(_ minutes: Double) -> String {
        if minutes >= 60 {
            return "\(Int(minutes / 60))h"
        }
        return "\(Int(minutes))m"
    }
}

private struct StudyTimeSessionRow: View {
    let session: StudyActivitySession

    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(session.category.chartColor)
                .frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.name ?? session.activity.title)
                    .font(.headline)
                Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(compactDuration(session.durationMs))
                .monospacedDigit()
        }
    }
}

private struct StudyTimeEntryView: View {
    let store: StudyTimeStore
    let session: StudyActivitySession?
    @Environment(\.dismiss) private var dismiss
    @State private var activity: StudyActivityKind
    @State private var name: String
    @State private var startedAt: Date
    @State private var minutes: Int
    @State private var durationWasAdjusted = false
    @State private var addToCalendar = false
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var entrySaved = false

    init(store: StudyTimeStore, session: StudyActivitySession? = nil) {
        self.store = store
        self.session = session
        _activity = State(initialValue: session?.activity ?? .tv)
        _name = State(initialValue: session?.name ?? "")
        _startedAt = State(initialValue: session?.startedAt ?? .now)
        _minutes = State(initialValue: max(1, (session?.durationMs ?? 1_800_000) / 60_000))
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Activity", selection: $activity) {
                    ForEach(StudyActivityKind.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                TextField("Name", text: $name)
                DatePicker("Started", selection: $startedAt, in: ...Date.now)
                Stepper(
                    "\(minutes) minutes",
                    value: Binding(
                        get: { minutes },
                        set: {
                            minutes = $0
                            durationWasAdjusted = true
                        }
                    ),
                    in: 1...1_440,
                    step: 5
                )
                if session == nil {
                    Toggle("Add to my calendar", isOn: $addToCalendar)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle(session == nil ? "Add Study Time" : "Edit Study Time")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else if entrySaved {
                            Text("Done")
                        } else {
                            Text(session == nil ? "Add" : "Save")
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    private func save() {
        if entrySaved {
            dismiss()
            return
        }
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                if let session {
                    let duration = durationWasAdjusted
                        ? TimeInterval(minutes * 60)
                        : TimeInterval(session.durationMs) / 1_000
                    let calendarWarning = try await store.update(
                        session: session,
                        activity: activity,
                        name: name.nilIfBlank,
                        startedAt: startedAt,
                        duration: duration
                    )
                    if let calendarWarning {
                        entrySaved = true
                        errorMessage =
                            "Study time was saved, but the linked calendar event "
                            + "could not be updated. \(calendarWarning)"
                    } else {
                        dismiss()
                    }
                } else {
                    let calendarWarning = try await store.recordCompleted(
                        activity: activity,
                        source: addToCalendar ? .calendar : .manual,
                        name: name.nilIfBlank,
                        startedAt: startedAt,
                        duration: TimeInterval(minutes * 60),
                        addToCalendar: addToCalendar
                    )
                    if let calendarWarning {
                        entrySaved = true
                        errorMessage =
                            "Study time was saved, but the calendar event was not added. "
                            + calendarWarning
                    } else {
                        dismiss()
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private extension StudyActivityCategory {
    var chartColor: Color {
        switch self {
        case .review: .blue
        case .listen: .cyan
        case .create: .orange
        case .immerse: .green
        case .conversation: .purple
        case .wanikani: .pink
        }
    }
}

private func compactDuration(_ milliseconds: Int) -> String {
    let totalMinutes = max(0, milliseconds / 60_000)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours == 0 {
        return "\(minutes)m"
    }
    if minutes == 0 {
        return "\(hours)h"
    }
    return "\(hours)h \(minutes)m"
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
