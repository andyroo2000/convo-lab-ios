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
    @State private var viewingQueue = false
    @State private var visible = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Study").font(StudyTimePaper.type(36, .largeTitle)).accessibilityAddTraits(.isHeader)
                    leaf(review: true)
                    leaf(review: false)
                    DailyAudioView(store: dailyAudio, player: drillPlayer, capabilities: store.capabilities.dailyAudio)
                    if store.cards.isEmpty, store.sessionCounts.hasRemainingReviews {
                        Button("Load Next Study Batch") { Task { await store.loadNextReviewBatch() } }
                            .disabled(store.syncStatus == .syncing)
                    }
                    if let error = store.storageWriteErrorMessage { Text(error).foregroundStyle(.red) }
                }.frame(maxWidth: 960)
                    .padding()
                    .frame(maxWidth: .infinity)
            }
            .background(StudyTimePaper.desk).foregroundStyle(StudyTimePaper.ink)
            .toolbar(hasAppModeHeader ? .hidden : .visible, for: .navigationBar)
            .preference(key: AppModeToolbarKey.self, value: visible ? [.study: syncToolbar] : [:])
            .onAppear { visible = true }.onDisappear { visible = false }
            .outsideDismissibleSheet(isPresented: $viewingQueue) {
                CardLibraryView(store: store, player: player, timeStore: timeStore)
                    .environment(\.hasAppModeHeader, false)
                    .presentationDragIndicator(.visible)
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

    private func leaf(review: Bool) -> some View {
        let count = review ? store.sessionCounts.failedDue + store.sessionCounts.reviewRemaining : store.sessionCounts.newRemaining
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
        return VStack(alignment: .leading, spacing: 10) {
            Text(review ? "Review" : "Learn").font(StudyTimePaper.type(26, .title2)).accessibilityAddTraits(.isHeader)
            layout {
                VStack(alignment: .leading, spacing: 3) {
                    layout {
                        Text(count.formatted()).font(StudyTimePaper.type(32, .title))
                        Text(review ? (count == 1 ? "card due" : "cards due") : (count == 1 ? "new card" : "new cards"))
                    }
                    if review {
                        Text(StudyTodayPresentation.reviewTimeText(reviewCount: count)).font(.footnote)
                    } else {
                        Button("View queue") { viewingQueue = true }.frame(minHeight: 44)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack {
                    NavigationLink {
                        StudySessionView(store: store, player: player, mode: review ? .reviews : .lessons, timeStore: timeStore)
                    } label: {
                        Text(review ? "Start review" : "Start lesson").padding(.horizontal, 14).frame(minHeight: 44)
                            .foregroundStyle(.white).background(StudyTimePaper.green, in: Capsule())
                    }.buttonStyle(.plain).disabled(count == 0).opacity(count == 0 ? 0.55 : 1)
                    .accessibilityLabel(review ? "Reviews, \(StudyTodayPresentation.reviewCountText(count))" : "Start lesson, \(count) new cards")
                    if review { Button("Browse cards ›", action: browseCards).frame(minHeight: 44) }
                }
            }
            if !review {
                Divider()
                StudyPileShelf(store: store, player: player, timeStore: timeStore)
            }
        }.font(StudyTimePaper.type(18)).padding(16)
        .background(StudyTimePaper.paper, in: .rect(cornerRadius: 13))
        .overlay(alignment: .top) { Rectangle().fill(StudyTimePaper.green.opacity(0.65)).frame(height: 4) }
        .clipShape(.rect(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).stroke(StudyTimePaper.ink.opacity(0.15)) }
    }
}
