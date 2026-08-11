import SwiftUI

struct CardLibraryView: View {
    private static let maximumReorderableCards = 100

    private enum CollectionMode: String, CaseIterable, Identifiable {
        case queue = "Queue"
        case all = "All Cards"

        var id: String { rawValue }
    }

    let store: StudyStore
    let player: StudyAudioPlayer
    let timeStore: StudyTimeStore?
    @State private var collectionMode: CollectionMode = .queue
    @State private var searchText = ""
    @State private var showingCreate = false
    @State private var selectedCard: StudyCard?
    @State private var selectedDraft: StudyManualCardDraft?
    @State private var showingDeletionError = false
    @State private var deletionErrorMessage = ""
    @State private var queueErrorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if collectionMode == .all {
                    cardList
                        .searchable(
                            text: $searchText,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search your cards"
                        )
                } else {
                    cardList
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Card collection", selection: $collectionMode) {
                    ForEach(CollectionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("Cards")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingCreate = true
                    } label: {
                        Label("Create Card", systemImage: "plus")
                    }
                }
                if collectionMode == .queue {
                    ToolbarItem(placement: .secondaryAction) {
                        EditButton()
                            .disabled(store.newCardQueue.count > Self.maximumReorderableCards)
                    }
                }
            }
            .sheet(isPresented: $showingCreate) {
                CardEditorView(
                    store: store,
                    player: player,
                    card: nil,
                    serverDraft: nil,
                    timeStore: timeStore
                )
            }
            .sheet(item: $selectedCard) { card in
                CardEditorView(
                    store: store,
                    player: player,
                    card: card,
                    serverDraft: nil,
                    timeStore: timeStore
                )
            }
            .sheet(item: $selectedDraft) { draft in
                CardEditorView(
                    store: store,
                    player: player,
                    card: nil,
                    serverDraft: draft,
                    timeStore: timeStore
                )
            }
            .alert("Could not delete card", isPresented: $showingDeletionError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deletionErrorMessage)
            }
            .task {
                try? await store.refreshManualDrafts()
                try? await store.refreshNewCardQueue()
            }
            .task(id: "\(collectionMode.rawValue)-\(searchText)") {
                guard collectionMode == .all else { return }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                try? await store.refreshAllCards(search: searchText)
            }
            .task(id: store.manualDrafts.filter { $0.status == "generating" }.map(\.id)) {
                while !Task.isCancelled,
                      store.manualDrafts.contains(where: { $0.status == "generating" })
                {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    try? await store.refreshManualDrafts()
                }
            }
            .refreshable {
                try? await store.refreshManualDrafts()
                await store.synchronize()
                try? await store.refreshNewCardQueue()
                if collectionMode == .all {
                    try? await store.refreshAllCards(search: searchText)
                }
            }
        }
    }

    @ViewBuilder
    private var cardList: some View {
        List {
            if collectionMode == .queue {
                if let queueErrorMessage {
                    Text(queueErrorMessage)
                        .foregroundStyle(.red)
                }
                Section {
                    ForEach(Array(store.newCardQueue.enumerated()), id: \.element.id) {
                        index,
                        item in
                        Group {
                            if let card = card(for: item) {
                                Button {
                                    selectedCard = card
                                } label: {
                                    queueRow(item, number: index + 1)
                                }
                            } else {
                                queueRow(item, number: index + 1)
                            }
                        }
                        .task {
                            guard item.id == store.newCardQueue.last?.id else { return }
                            try? await store.loadMoreNewCardQueue()
                        }
                    }
                    .onMove { offsets, destination in
                        // The API deliberately reassigns only the submitted cards across
                        // their existing queue positions; cards on unloaded pages stay put.
                        guard store.newCardQueue.count <= Self.maximumReorderableCards else {
                            queueErrorMessage =
                                "Reordering is available while up to \(Self.maximumReorderableCards) cards are loaded."
                            return
                        }
                        Task {
                            do {
                                try await store.moveNewCards(
                                    fromOffsets: offsets,
                                    toOffset: destination
                                )
                                queueErrorMessage = nil
                            } catch {
                                queueErrorMessage = error.localizedDescription
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Up Next")
                        Spacer()
                        Text("\(store.newCardQueueTotal.formatted()) queued")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                } footer: {
                    if store.newCardQueue.count > Self.maximumReorderableCards {
                        Text(
                            "Reordering is available while up to \(Self.maximumReorderableCards) cards are loaded."
                        )
                    } else if store.newCardQueueTotal > store.newCardQueue.count {
                        Text(
                            "Showing the next \(store.newCardQueue.count) of \(store.newCardQueueTotal) cards."
                        )
                    } else {
                        Text("Tap Edit, then drag the handles to change the study order.")
                    }
                }
            } else {
                if !store.manualDrafts.isEmpty {
                    Section("Creation drafts") {
                        ForEach(store.manualDrafts) { draft in
                            Button {
                                selectedDraft = draft
                            } label: {
                                draftRow(draft)
                            }
                            .disabled(draft.status == "generating")
                        }
                    }
                }

                if !store.allCards.isEmpty {
                    Section {
                        ForEach(store.allCards) { card in
                            Group {
                                if StudyCardDraft.CardType(rawValue: card.cardType) != nil {
                                    Button {
                                        selectedCard = card
                                    } label: {
                                        cardRow(card)
                                    }
                                } else {
                                    cardRow(card)
                                }
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    Task { await delete(card) }
                                }
                            }
                            .task {
                                guard card.id == store.allCards.last?.id else { return }
                                try? await store.loadMoreAllCards()
                            }
                        }
                        if store.isLoadingMoreAllCards {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        }
                    } header: {
                        HStack {
                            Text("Cards")
                            Spacer()
                            Text("\(totalCardCount.formatted()) total")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                    }
                }
            }
        }
        .overlay {
            if collectionMode == .queue, store.newCardQueue.isEmpty {
                ContentUnavailableView(
                    store.isRefreshingNewCardQueue ? "Loading queue…" : "Queue is empty",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    description: Text("New cards waiting to be introduced appear here.")
                )
            } else if collectionMode == .all,
                      store.allCards.isEmpty,
                      store.manualDrafts.isEmpty {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        store.isRefreshingAllCards ? "Loading cards…" : "No cards",
                        systemImage: "rectangle.stack",
                        description: Text("Sync or create a card to begin.")
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    private var totalCardCount: Int {
        store.overview.flatMap { $0.totalCards > 0 ? $0.totalCards : nil }
            ?? store.libraryCards.count
    }

    private func card(for item: StudyNewCardQueueItem) -> StudyCard? {
        store.allCards.first { $0.id == item.id }
            ?? store.libraryCards.first { $0.id == item.id }
    }

    private func queueRow(_ item: StudyNewCardQueueItem, number: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayText)
                    .font(.headline)
                    .foregroundStyle(ConvoLabTheme.navy)
                if let meaning = item.meaning, !meaning.isEmpty {
                    Text(meaning)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Queue position \(number), \(item.displayText)")
    }

    private func draftRow(_ draft: StudyManualCardDraft) -> some View {
        let recoveryState = store.draftCommitRecoveryState(for: draft.id)
        return HStack(spacing: 12) {
            Image(
                systemName: recoveryState == .cleanupPending
                    ? "checkmark.circle"
                    : recoveryState == .rejected
                    ? "exclamationmark.circle"
                    : recoveryState == .outcomeUnknown
                    ? "arrow.clockwise.circle"
                    : draft.status == "generating"
                    ? "sparkles"
                    : draft.status == "error" ? "exclamationmark.triangle" : "doc.badge.gearshape"
            )
            .foregroundStyle(draft.status == "error" ? .red : ConvoLabTheme.navy)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(draft.creationKind.title)
                    .font(.headline)
                    .foregroundStyle(ConvoLabTheme.navy)
                Text(
                    recoveryState == .cleanupPending
                        ? "Card created; tap to finish cleanup"
                        : recoveryState == .rejected
                        ? "Commit rejected; tap to edit and retry"
                        : recoveryState == .outcomeUnknown
                        ? "Commit outcome unknown; tap to retry"
                        : draft.status == "generating"
                        ? "Preparing fields and media…"
                        : draft.errorMessage ?? "Ready to review and create"
                )
                .font(.caption)
                .foregroundStyle(draft.status == "error" ? .red : .secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func cardRow(_ card: StudyCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.promptText)
                .font(.headline)
                .foregroundStyle(ConvoLabTheme.navy)
            Text(card.answerText)
                .lineLimit(2)
                .foregroundStyle(.secondary)
            Text(card.cardType.capitalized)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func delete(_ card: StudyCard) async {
        do {
            try await store.deleteCard(card)
        } catch {
            deletionErrorMessage = error.localizedDescription
            showingDeletionError = true
        }
    }
}
