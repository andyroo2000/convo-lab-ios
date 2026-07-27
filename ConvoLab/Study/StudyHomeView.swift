import SwiftUI

struct StudyHomeView: View {
    let store: StudyStore
    let player: StudyAudioPlayer

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    studyActions
                    learningReadiness
                    masterySpread
                    readiness

                    if store.cards.isEmpty, store.sessionCounts.hasRemainingStudy {
                        ContentUnavailableView {
                            Label("More cards are ready", systemImage: "rectangle.stack.badge.plus")
                        } description: {
                            Text("Load the next study batch to keep going.")
                        } actions: {
                            Button("Load Next Study Batch") {
                                Task { await store.synchronize() }
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
                        Task { await store.synchronize() }
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
            }
            .onAppear {
                Task {
                    await store.synchronizeIfNeeded(maxAge: .seconds(60))
                }
            }
        }
    }

    private var studyActions: some View {
        HStack(spacing: 12) {
            NavigationLink {
                StudySessionView(store: store, player: player, mode: .reviews)
            } label: {
                Label("Reviews", systemImage: "rectangle.stack.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(ConvoLabTheme.navy)
            .disabled(
                store.sessionCounts.reviewRemaining == 0
                    && store.sessionCounts.failedDue == 0
            )

            NavigationLink {
                StudySessionView(store: store, player: player, mode: .lessons)
            } label: {
                Label("Lessons", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(store.sessionCounts.newRemaining == 0)
        }
    }

    @ViewBuilder
    private var learningReadiness: some View {
        if let recommendation = store.overview?.learningReadiness {
            VStack(alignment: .leading, spacing: 8) {
                Label("Learning readiness", systemImage: readinessIcon(recommendation.recommendation))
                    .font(.headline)
                Text(readinessTitle(recommendation.recommendation))
                    .font(.title3.bold())
                if recommendation.sufficientData, let recall = recommendation.recentRecall {
                    Text(
                        "Recent recall is \(Int((recall * 100).rounded()))%. "
                            + "\(recommendation.apprenticeCount) Apprentice cards need reinforcement, "
                            + "with \(recommendation.projectedSevenDayReviews) reviews projected over seven days."
                    )
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
                Text("This is advice, not a lock. Lessons always remain available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Suggested next lesson: \(recommendation.suggestedBatchSize) cards.")
                    .font(.caption.bold())
                    .foregroundStyle(ConvoLabTheme.navy)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.72), in: .rect(cornerRadius: 18))
        }
    }

    @ViewBuilder
    private var masterySpread: some View {
        if let spread = store.overview?.masterySpread {
            VStack(alignment: .leading, spacing: 10) {
                Text("Item Spread")
                    .font(.headline)
                masteryRow("Apprentice", count: spread.apprentice, color: .pink)
                masteryRow("Guru", count: spread.guru, color: .purple)
                masteryRow("Master", count: spread.master, color: .blue)
                masteryRow("Enlightened", count: spread.enlightened, color: .orange)
                masteryRow("Burned", count: spread.burned, color: .green)
                Text("Levels are derived from FSRS stability; Burned cards still follow FSRS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.white.opacity(0.72), in: .rect(cornerRadius: 18))
        }
    }

    private func masteryRow(_ title: String, count: Int, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
            Spacer()
            Text(count, format: .number).monospacedDigit()
        }
        .font(.subheadline)
    }

    private func readinessTitle(_ recommendation: String) -> String {
        switch recommendation {
        case "pause": "Reviews first recommended"
        case "caution": "Add new cards carefully"
        default: "Good time to learn"
        }
    }

    private func readinessIcon(_ recommendation: String) -> String {
        switch recommendation {
        case "pause": "pause.circle.fill"
        case "caution": "exclamationmark.triangle.fill"
        default: "checkmark.circle.fill"
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            metric(title: "Failed", value: store.sessionCounts.failedDue)
            metric(title: "Due", value: store.sessionCounts.reviewRemaining)
            metric(title: "New", value: store.sessionCounts.newRemaining)
        }
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

            Text(readinessDescription(target: target))
                .font(.footnote)
                .foregroundStyle(.secondary)

            syncStatus
        }
        .padding()
        .background(.white.opacity(0.72), in: .rect(cornerRadius: 18))
    }

    @ViewBuilder
    private var syncStatus: some View {
        switch store.syncStatus {
        case .idle:
            if let lastSyncAt = store.lastSyncAt {
                Text("Last synced \(lastSyncAt, format: .relative(presentation: .named))")
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

    private func readinessDescription(target: Int) -> String {
        "\(store.preparedCardCount) of \(target) planned cards are ready offline. Cards with audio or images count only after every file downloads."
    }

    private func metric(title: String, value: Int) -> some View {
        VStack(spacing: 3) {
            Text(value, format: .number)
                .font(.title.bold())
                .foregroundStyle(ConvoLabTheme.navy)
            Text(title.uppercased())
                .font(.caption2.bold())
                .tracking(1.2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
        .background(.white.opacity(0.72), in: .rect(cornerRadius: 18))
    }
}
