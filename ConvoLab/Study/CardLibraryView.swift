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
    @State private var showingCardLoadError = false
    @State private var cardLoadErrorMessage = ""
    @State private var queueErrorMessage: String?
    @State private var expandedLearningItemIDs: Set<String> = []

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
            .alert("Could not open card", isPresented: $showingCardLoadError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(cardLoadErrorMessage)
            }
            .task {
                try? await store.refreshManualDrafts()
                try? await store.refreshNewCardQueue()
            }
            .task(id: "\(collectionMode.rawValue)-\(searchText)") {
                guard collectionMode == .all else { return }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                try? await store.refreshLearningItems(search: searchText)
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
                    try? await store.refreshLearningItems(search: searchText)
                }
            }
        }
    }

    @ViewBuilder
    private var cardList: some View {
        List {
            if !store.pendingManualDraftCreates.isEmpty {
                Section("Card creation recovery") {
                    ForEach(store.pendingManualDraftCreates, id: \.id) { request in
                        Button {
                            selectedDraft = recoveredDraft(for: request)
                        } label: {
                            Label(
                                "Resume \(request.creationKind.title.lowercased()) draft",
                                systemImage: "arrow.clockwise.circle"
                            )
                        }
                        .accessibilityIdentifier("pending-card-create-\(request.id)")
                    }
                }
            }

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
                            } else if StudyCardDraft.CardType(rawValue: item.cardType) != nil {
                                Button {
                                    open(item)
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

                if !store.learningItems.isEmpty {
                    Section {
                        ForEach(store.learningItems) { item in
                            learningItemRow(item)
                            .task {
                                guard item.id == store.learningItems.last?.id else { return }
                                try? await store.loadMoreLearningItems()
                            }
                        }
                        if store.isLoadingMoreLearningItems {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        }
                    } header: {
                        HStack {
                            Text("Cards")
                            Spacer()
                            Text(
                                store.learningItemsNextCursor == nil
                                    ? "\(store.learningItems.count.formatted()) learning items"
                                    : "\(store.learningItems.count.formatted()) loaded"
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                    }
                }
            }
        }
        .overlay {
            if collectionMode == .queue,
               store.newCardQueue.isEmpty,
               store.pendingManualDraftCreates.isEmpty {
                ContentUnavailableView(
                    store.isRefreshingNewCardQueue ? "Loading queue…" : "Queue is empty",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    description: Text("New cards waiting to be introduced appear here.")
                )
            } else if collectionMode == .all,
                      store.learningItems.isEmpty,
                      store.manualDrafts.isEmpty,
                      store.pendingManualDraftCreates.isEmpty {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        store.isRefreshingLearningItems ? "Loading cards…" : "No cards",
                        systemImage: "rectangle.stack",
                        description: Text("Sync or create a card to begin.")
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    private func recoveredDraft(
        for request: CreateStudyManualCardDraftRequest
    ) -> StudyManualCardDraft {
        StudyManualCardDraft(
            id: request.id,
            status: "pending",
            committedCardId: nil,
            creationKind: request.creationKind,
            cardType: request.cardType,
            prompt: request.prompt,
            answer: request.answer,
            imagePlacement: request.imagePlacement,
            imagePrompt: request.imagePrompt,
            previewAudio: nil,
            previewAudioRole: nil,
            previewImage: nil,
            errorMessage: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
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

    @ViewBuilder
    private func learningItemRow(_ item: StudyLearningItem) -> some View {
        if item.groupId == nil {
            if let card = store.card(for: item.representativeCard),
               StudyCardDraft.CardType(rawValue: card.cardType) != nil {
                Button {
                    selectedCard = card
                } label: {
                    learningItemSummary(item)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        Task { await delete(card) }
                    }
                }
            } else if StudyCardDraft.CardType(
                rawValue: item.representativeCard.cardType
            ) != nil {
                Button {
                    open(item.representativeCard)
                } label: {
                    learningItemSummary(item)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        Task { await delete(item.representativeCard) }
                    }
                }
            } else {
                learningItemSummary(item)
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            Task { await delete(item.representativeCard) }
                        }
                    }
            }
        } else {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedLearningItemIDs.contains(item.id) },
                    set: { isExpanded in
                        if isExpanded {
                            expandedLearningItemIDs.insert(item.id)
                        } else {
                            expandedLearningItemIDs.remove(item.id)
                        }
                    }
                )
            ) {
                ForEach(item.stages) { stage in
                    learningStageRow(stage)
                }
            } label: {
                learningItemSummary(item)
            }
        }
    }

    private func learningItemSummary(_ item: StudyLearningItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.representativeCard.displayText)
                    .font(.headline)
                    .foregroundStyle(ConvoLabTheme.navy)
                Spacer(minLength: 8)
                if item.transferDemonstrated {
                    Label("Transfer", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            if let meaning = item.representativeCard.meaning, !meaning.isEmpty {
                Text(meaning)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            if item.groupId != nil {
                HStack(spacing: 8) {
                    Label("Learning path", systemImage: "square.stack.3d.up")
                    if let currentStage = item.currentStageNumber {
                        Text("Stage \(currentStage) of \(item.stageCount)")
                    } else {
                        Text("\(item.stageCount) stages")
                    }
                    Text("\(item.cardCount) cards")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                stageRail(item)
            } else {
                Text(item.representativeCard.cardType.capitalized)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stageRail(_ item: StudyLearningItem) -> some View {
        HStack(spacing: 4) {
            ForEach(item.stages) { stage in
                Capsule()
                    .fill(stageColor(stage.status))
                    .frame(height: 4)
            }
        }
        .accessibilityHidden(true)
    }

    private func learningStageRow(_ stage: StudyLearningItemStage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: stageIcon(stage.status))
                    .foregroundStyle(stageColor(stage.status))
                    .accessibilityHidden(true)
                Text(stage.number.map { "Stage \($0)" } ?? "Stage")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(stageStatusText(stage.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(stage.cards) { itemCard in
                if let card = store.card(for: itemCard),
                   StudyCardDraft.CardType(rawValue: card.cardType) != nil {
                    HStack {
                        Button {
                            selectedCard = card
                        } label: {
                            learningItemCardRow(itemCard)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        Button(role: .destructive) {
                            Task { await delete(card) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete card")
                    }
                } else if StudyCardDraft.CardType(rawValue: itemCard.cardType) != nil {
                    HStack {
                        Button {
                            open(itemCard)
                        } label: {
                            learningItemCardRow(itemCard)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        Button(role: .destructive) {
                            Task { await delete(itemCard) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete card")
                    }
                } else {
                    HStack {
                        learningItemCardRow(itemCard)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(role: .destructive) {
                            Task { await delete(itemCard) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete card")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func learningItemCardRow(_ card: StudyLearningItemCard) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(card.displayText)
                .foregroundStyle(ConvoLabTheme.navy)
            if let meaning = card.meaning, !meaning.isEmpty {
                Text(meaning)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 26)
    }

    private func stageColor(_ status: StudyLearningItemStageStatus?) -> Color {
        switch status {
        case .available: ConvoLabTheme.navy
        case .retired: .green
        case .locked, .unknown, nil: .gray.opacity(0.45)
        }
    }

    private func stageIcon(_ status: StudyLearningItemStageStatus?) -> String {
        switch status {
        case .available: "play.circle.fill"
        case .retired: "checkmark.circle.fill"
        case .locked, .unknown, nil: "lock.circle.fill"
        }
    }

    private func stageStatusText(_ status: StudyLearningItemStageStatus?) -> String {
        switch status {
        case .available: "Available"
        case .retired: "Retired"
        case .locked: "Locked"
        case .unknown: "Unknown"
        case nil: "Stage"
        }
    }

    private func open(_ item: StudyNewCardQueueItem) {
        Task {
            do {
                guard let card = try await store.resolveCard(for: item) else {
                    cardLoadErrorMessage = "This card is no longer available."
                    showingCardLoadError = true
                    return
                }
                selectedCard = card
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                cardLoadErrorMessage = error.localizedDescription
                showingCardLoadError = true
            }
        }
    }

    private func open(_ itemCard: StudyLearningItemCard) {
        Task {
            do {
                guard let card = try await store.resolveCard(for: itemCard) else {
                    cardLoadErrorMessage = "This card is no longer available."
                    showingCardLoadError = true
                    return
                }
                selectedCard = card
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                cardLoadErrorMessage = error.localizedDescription
                showingCardLoadError = true
            }
        }
    }

    private func delete(_ card: StudyCard) async {
        do {
            try await store.deleteCard(card)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            deletionErrorMessage = error.localizedDescription
            showingDeletionError = true
        }
    }

    private func delete(_ itemCard: StudyLearningItemCard) async {
        do {
            guard let card = try await store.resolveCard(for: itemCard) else {
                deletionErrorMessage = "This card is no longer available."
                showingDeletionError = true
                return
            }
            try await store.deleteCard(card)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            deletionErrorMessage = error.localizedDescription
            showingDeletionError = true
        }
    }
}
