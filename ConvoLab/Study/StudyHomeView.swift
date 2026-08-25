import SwiftUI

struct StudyHomeView: View {
    let store: StudyStore
    let player: StudyAudioPlayer
    let timeStore: StudyTimeStore?
    @State private var showingFailedChanges = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    todayPlan
                    learningReadiness
                    masterySpread
                    readiness

                    if store.cards.isEmpty, store.sessionCounts.hasRemainingReviews {
                        ContentUnavailableView {
                            Label("More cards are ready", systemImage: "rectangle.stack.badge.plus")
                        } description: {
                            Text("Load the next study batch to keep going.")
                        } actions: {
                            Button("Load Next Study Batch") {
                                Task { await store.loadNextReviewBatch() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ConvoLabTheme.navy)
                            .disabled(store.syncStatus == .syncing)
                        }
                        .padding(.vertical, 48)
                    }
                }
                .padding()
            }
            .paperBackground()
            .navigationTitle("Study")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await store.synchronize()
                            await refreshWaniKaniIfNeeded(force: true)
                            await refreshCalendarIfNeeded(force: true)
                        }
                    } label: {
                        if store.syncStatus == .syncing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.trianglehead.2.clockwise")
                        }
                    }
                    .accessibilityLabel("Sync")
                }
            }
            .refreshable {
                await store.synchronize()
                await refreshWaniKaniIfNeeded(force: true)
                await refreshCalendarIfNeeded(force: true)
            }
            .task {
                // Cached state is already visible. Leave the first interaction window
                // free before starting non-urgent main-actor refresh coordination.
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                async let study: Void = refreshStudyIfNeeded()
                async let calendar: Void = refreshCalendarIfNeeded()
                _ = await (study, calendar)
            }
            .sheet(isPresented: $showingFailedChanges) {
                FailedStudyChangesView(store: store)
            }
        }
    }

    private var todayPlan: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today")
                .font(.caption2.bold())
                .tracking(1.8)
                .foregroundStyle(ConvoLabTheme.navy.opacity(0.62))
                .padding(.leading, 4)

            VStack(spacing: 0) {
                reviewAction

                HStack(spacing: 0) {
                    lessonAction
                    Divider()
                    waniKaniAction
                }
                .fixedSize(horizontal: false, vertical: true)

                if let timeStore,
                   let nextLesson = timeStore.googleCalendarStatus?.nextLesson
                {
                    Divider()
                    NavigationLink {
                        StudyTimeView(store: timeStore, studyStore: store)
                    } label: {
                        nextLessonLabel(nextLesson)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(.white.opacity(0.82))
            .clipShape(.rect(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(ConvoLabTheme.navy.opacity(0.1), lineWidth: 1)
            }
            .shadow(color: ConvoLabTheme.navy.opacity(0.08), radius: 12, y: 5)

            Text("\(totalCardCount.formatted()) cards total")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 4)
        }
    }

    private var reviewAction: some View {
        NavigationLink {
            StudySessionView(
                store: store,
                player: player,
                mode: .reviews,
                timeStore: timeStore
            )
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ConvoLab reviews")
                        .font(.subheadline.bold())
                        .foregroundStyle(ConvoLabTheme.cream.opacity(0.8))
                    Text(StudyTodayPresentation.reviewCountText(reviewAvailableCount))
                        .font(.title.bold())
                        .foregroundStyle(ConvoLabTheme.cream)
                    Text(reviewTimeText)
                        .font(.footnote)
                        .foregroundStyle(ConvoLabTheme.cream.opacity(0.72))
                }
                Spacer(minLength: 8)
                Image(systemName: "play.fill")
                    .font(.title3.bold())
                    .foregroundStyle(ConvoLabTheme.navy)
                    .frame(width: 54, height: 54)
                    .background(ConvoLabTheme.cream, in: .circle)
                    .shadow(color: .black.opacity(0.16), radius: 7, y: 3)
                    .accessibilityHidden(true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
            .background(ConvoLabTheme.navy)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(reviewAvailableCount == 0)
        .accessibilityLabel(
            "ConvoLab reviews, \(StudyTodayPresentation.reviewCountText(reviewAvailableCount)), \(reviewTimeText)"
        )
    }

    private var lessonAction: some View {
        NavigationLink {
            StudySessionView(
                store: store,
                player: player,
                mode: .lessons,
                timeStore: timeStore
            )
        } label: {
            todayTile(
                title: "Lessons",
                detail: StudyTodayPresentation.newCardCountText(store.sessionCounts.newRemaining),
                systemImage: "book.closed.fill",
                color: .green
            )
        }
        .buttonStyle(.plain)
        .disabled(store.sessionCounts.newRemaining == 0)
    }

    private var waniKaniAction: some View {
        NavigationLink {
            WaniKaniBrowserView(timeStore: timeStore)
        } label: {
            todayTile(
                title: "WaniKani",
                detail: store.wanikaniReviewCount.map(StudyTodayPresentation.reviewCountText)
                    ?? "Open reviews",
                systemImage: "character.ja",
                color: ConvoLabTheme.coral
            )
        }
        .buttonStyle(.plain)
    }

    private func todayTile(
        title: String,
        detail: String,
        systemImage: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: systemImage)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color, in: .rect(cornerRadius: 9))
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(ConvoLabTheme.navy)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .padding(16)
        .contentShape(.rect)
    }

    private func nextLessonLabel(_ lesson: GoogleCalendarNextLesson) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.body.bold())
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(ConvoLabTheme.cyan, in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Next lesson")
                    .font(.caption2.bold())
                    .textCase(.uppercase)
                    .tracking(1)
                    .foregroundStyle(.secondary)
                Text(lesson.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(ConvoLabTheme.navy)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(StudyTodayPresentation.lessonTiming(lesson.startsAt))
                .font(.caption.bold())
                .foregroundStyle(ConvoLabTheme.navy)
                .multilineTextAlignment(.trailing)
        }
        .padding(14)
        .contentShape(.rect)
    }

    private var reviewAvailableCount: Int {
        store.sessionCounts.failedDue + store.sessionCounts.reviewRemaining
    }

    private var reviewTimeText: String {
        StudyTodayPresentation.reviewTimeText(reviewCount: reviewAvailableCount)
    }

    private var totalCardCount: Int {
        store.overview.flatMap { $0.totalCards > 0 ? $0.totalCards : nil }
            ?? store.libraryCards.count
    }

    private func refreshWaniKaniIfNeeded(force: Bool = false) async {
        guard store.wanikaniConnected else { return }
        guard force || StudyTodayPresentation.shouldRefreshWaniKani(
            reviewCountUpdatedAt: store.wanikaniReviewCountUpdatedAt
        ) else { return }

        await store.syncWaniKani()
    }

    private func refreshStudyIfNeeded() async {
        await store.synchronizeIfNeeded(maxAge: .seconds(60))
        guard !Task.isCancelled else { return }
        await refreshWaniKaniIfNeeded()
    }

    private func refreshCalendarIfNeeded(force: Bool = false) async {
        guard let timeStore else { return }
        guard force || StudyTodayPresentation.shouldRefreshCalendar(
            statusFetchedAt: timeStore.googleCalendarStatusRefreshedAt
        ) else { return }

        await timeStore.loadGoogleCalendarConnection()
    }

    @ViewBuilder
    private var learningReadiness: some View {
        if let recommendation = store.overview?.learningReadiness {
            let level = recommendation.readinessLevel ?? recommendation.recommendation
            VStack(alignment: .leading, spacing: 8) {
                Label("Learning readiness", systemImage: readinessIcon(level))
                    .font(.headline)
                Text(readinessTitle(level))
                    .font(.title3.bold())
                if recommendation.sufficientData, let recall = recommendation.recentRecall {
                    Text(readinessDescription(recommendation, recall: recall))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        "Building a recommendation from your first 30 answers "
                            + "(\(recommendation.sampleSize) so far)."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.72), in: .rect(cornerRadius: 18))
        }
    }

    @ViewBuilder
    private var masterySpread: some View {
        if let spread = store.overview?.masterySpread {
            StudyMasterySpreadView(spread: spread)
        }
    }

    private func readinessTitle(_ level: String) -> String {
        switch level {
        case "baseline": "Building your baseline"
        case "pause": "Reviews first"
        case "ease_up", "caution": "Ease up on new cards"
        case "steady": "Steady pace"
        case "strong": "Strong capacity"
        default: "Good time to learn"
        }
    }

    private func readinessIcon(_ level: String) -> String {
        switch level {
        case "pause": "pause.circle.fill"
        case "ease_up", "caution": "exclamationmark.triangle.fill"
        case "baseline": "chart.line.uptrend.xyaxis"
        case "steady": "equal.circle.fill"
        case "strong": "bolt.circle.fill"
        default: "checkmark.circle.fill"
        }
    }

    private func readinessDescription(
        _ readiness: StudyLearningReadiness,
        recall: Double
    ) -> String {
        let recallText = "Recent recall is \(Int((recall * 100).rounded()))%."

        guard
            let projectedMinutes = readiness.projectedDailyReviewMinutes,
            let budgetMinutes = readiness.reviewTimeBudgetMinutes,
            let headroomMinutes = readiness.reviewTimeHeadroomMinutes
        else {
            let timedAnswers = readiness.timedReviewSampleSize ?? 0
            return "\(recallText) Review timing is still calibrating (\(timedAnswers) timed answers so far)."
        }

        if headroomMinutes >= 0 {
            return "\(recallText) About \(projectedMinutes) min/day are scheduled, leaving \(headroomMinutes) min inside your \(budgetMinutes)-minute review budget."
        }

        return "\(recallText) About \(projectedMinutes) min/day are scheduled, \(-headroomMinutes) min over your \(budgetMinutes)-minute review budget."
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Offline readiness", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                Spacer()
                Text("5 days")
                    .font(.caption.bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(ConvoLabTheme.cyan.opacity(0.18), in: .capsule)
            }

            let target = store.offlineReadinessTarget
            ProgressView(value: Double(min(store.preparedCardCount, target)), total: Double(max(target, 1)))
                .tint(ConvoLabTheme.cyan)
                .accessibilityLabel("Offline readiness")
                .accessibilityValue(
                    "\(min(store.preparedCardCount, target)) of \(target) cards ready"
                )

            syncStatus

            if !store.failedStudyChanges.isEmpty {
                Button {
                    showingFailedChanges = true
                } label: {
                    Label(
                        "Review \(store.failedStudyChanges.count) failed \(store.failedStudyChanges.count == 1 ? "change" : "changes")",
                        systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
        }
        .padding()
        .background(.white.opacity(0.72), in: .rect(cornerRadius: 18))
    }

    @ViewBuilder
    private var syncStatus: some View {
        if let message = store.storageWriteErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            switch store.syncStatus {
            case .idle:
                if let lastSyncAt = store.lastSyncAt {
                    Text("Last sync: \(lastSyncAt, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .syncing:
                Label("Preparing study media…", systemImage: "arrow.down.circle")
                    .font(.caption)
            case .offline:
                Label("Offline — saved work will sync later", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

}
