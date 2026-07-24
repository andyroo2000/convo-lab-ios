import SwiftUI

struct StudyHomeView: View {
    let store: StudyStore
    @State private var player = StudyAudioPlayer()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    readiness

                    if store.cards.isEmpty {
                        ContentUnavailableView(
                            "You’re caught up",
                            systemImage: "sparkles",
                            description: Text("Sync when you’re online to check for newly due cards.")
                        )
                        .padding(.vertical, 48)
                    } else {
                        NavigationLink {
                            StudySessionView(store: store, player: player)
                        } label: {
                            Label("Start \(store.cards.count)-card session", systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ConvoLabTheme.navy)
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
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            metric(title: "Due", value: store.overview?.dueCount ?? store.cards.count)
            metric(title: "New", value: store.overview?.newCount ?? 0)
            metric(title: "Daily", value: store.overview?.newCardsPerDay ?? 0)
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

            let target = max(store.cards.count, store.fiveDayNewCardTarget)
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
        "\(store.preparedCardCount) of \(target) planned cards have local media. The target uses five times your daily new-card limit."
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
