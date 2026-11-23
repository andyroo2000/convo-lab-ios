import SwiftUI

struct StudyHomeView: View {
    let store: StudyStore
    let player: StudyAudioPlayer
    let timeStore: StudyTimeStore?
    let dailyAudio: DailyAudioStore
    let drillPlayer: AudioPlayer
    var browseCards: () -> Void = {}
    var automaticSynchronization: (() async -> Void)?
    @Environment(\.hasAppModeHeader) private var hasAppModeHeader
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var choosingPile = false
    @State private var visible = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Study").font(StudyTimePaper.type(36, .largeTitle)).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Text(Date.now, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    spread
                    DailyAudioView(store: dailyAudio, player: drillPlayer, capabilities: store.capabilities.dailyAudio)
                    if store.cards.isEmpty, store.sessionCounts.hasRemainingReviews {
                        Button("Load Next Study Batch") { Task { await store.loadNextReviewBatch() } }
                            .disabled(store.syncStatus == .syncing)
                    }
                    if let error = store.storageWriteErrorMessage { Text(error).foregroundStyle(.red) }
                }.padding()
            }
            .background(StudyTimePaper.desk).foregroundStyle(StudyTimePaper.ink)
            .toolbar(hasAppModeHeader ? .hidden : .visible, for: .navigationBar)
            .preference(key: AppModeToolbarKey.self, value: visible ? [.study: syncToolbar] : [:])
            .onAppear { visible = true }.onDisappear { visible = false }
            .navigationDestination(isPresented: $choosingPile) {
                ScrollView { StudyPileShelf(store: store, player: player, timeStore: timeStore).padding() }
                    .navigationTitle("Choose a pile")
            }
            .refreshable {
                await store.synchronize()
                _ = await dailyAudio.refresh()
            }
            .task {
                if let automaticSynchronization { await automaticSynchronization() }
                else { await store.synchronizeIfNeeded(maxAge: .seconds(60)) }
            }
        }
    }

    private var syncToolbar: AppModeToolbar {
        AppModeToolbar(buttons: [AppModeToolbarAction(id: "StudySyncButton", title: "Sync",
            icon: "arrow.trianglehead.2.clockwise", isEnabled: store.syncStatus != .syncing,
            isLoading: store.syncStatus == .syncing) { Task { await store.synchronize() } }])
    }

    private var spread: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
        return layout {
            leaf(review: true)
            Divider()
            leaf(review: false)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(StudyTimePaper.paper, in: .rect(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).stroke(StudyTimePaper.ink.opacity(0.18)) }
    }

    private func leaf(review: Bool) -> some View {
        let count = review ? store.sessionCounts.failedDue + store.sessionCounts.reviewRemaining : store.sessionCounts.newRemaining
        return VStack(alignment: .leading, spacing: 6) {
            Text(review ? "Review" : "Learn").font(StudyTimePaper.type(26, .title2)).accessibilityAddTraits(.isHeader)
            Text(count.formatted()).font(StudyTimePaper.type(38, .largeTitle))
            Text(review ? (count == 1 ? "card due" : "cards due") : (count == 1 ? "new card" : "new cards"))
                .font(StudyTimePaper.type(18))
            Text(review ? StudyTodayPresentation.reviewTimeText(reviewCount: count) : "My usual mix")
                .font(.footnote).foregroundStyle(.secondary)
            NavigationLink {
                StudySessionView(store: store, player: player, mode: review ? .reviews : .lessons, timeStore: timeStore)
            } label: {
                Text(review ? "Start review" : "Start lesson")
                    .font(StudyTimePaper.type(18)).padding(.horizontal, 11).frame(minHeight: 44)
                    .foregroundStyle(review ? .white : StudyTimePaper.green)
                    .background(review ? StudyTimePaper.green : .clear, in: Capsule())
                    .overlay { Capsule().stroke(StudyTimePaper.green) }
            }
            .buttonStyle(.plain).disabled(count == 0).opacity(count == 0 ? 0.55 : 1)
            .accessibilityLabel(review ? "Reviews, \(StudyTodayPresentation.reviewCountText(count))" : "Start lesson, \(count) new cards")
            Button(review ? "Browse cards ›" : "Choose a pile ›") {
                if review { browseCards() } else { choosingPile = true }
            }.font(StudyTimePaper.type(17)).frame(minHeight: 44)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }
}
