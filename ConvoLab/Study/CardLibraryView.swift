import PhotosUI
import SwiftUI

struct CardLibraryView: View {
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
                            .disabled(store.newCardQueue.count > 100)
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
                        guard store.newCardQueue.count <= 100 else {
                            queueErrorMessage =
                                "Reordering is available while up to 100 cards are loaded."
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
                    if store.newCardQueue.count > 100 {
                        Text("Reordering is available while up to 100 cards are loaded.")
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

private struct CameraImagePicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate,
        UIImagePickerControllerDelegate
    {
        let onImage: (UIImage) -> Void
        let dismiss: DismissAction

        init(onImage: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onImage = onImage
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

struct CardEditorView: View {
    private enum IndependentImageAction: String, Identifiable {
        case save
        case regenerate

        var id: String { rawValue }
    }

    let store: StudyStore
    let player: StudyAudioPlayer
    let card: StudyCard?
    let serverDraft: StudyManualCardDraft?
    let timeStore: StudyTimeStore?
    @Environment(\.scenePhase) private var scenePhase

    @State private var draft: StudyCardDraft
    @State private var clientDraftID: String
    @State private var creationKind: StudyCardCreationKind
    @State private var previewAudio: JSONValue?
    @State private var previewAudioRole: String?
    @State private var previewImage: JSONValue?
    @State private var isSaving = false
    @State private var isRegeneratingAudio = false
    @State private var isRegeneratingImage = false
    @State private var audioRegenerationTask: Task<Void, Never>?
    @State private var imageRegenerationTask: Task<Void, Never>?
    @State private var answerAudioLocalURL: URL?
    @State private var promptImageLocalURL: URL?
    @State private var answerImageLocalURL: URL?
    @State private var sharedImageLocalURL: URL?
    @State private var promptImagePreview: UIImage?
    @State private var answerImagePreview: UIImage?
    @State private var originalPromptImageLocalURL: URL?
    @State private var originalAnswerImageLocalURL: URL?
    @State private var originalPromptImagePreview: UIImage?
    @State private var originalAnswerImagePreview: UIImage?
    @State private var sharedImagePreview: UIImage?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var stagedPhotoData: Data?
    @State private var stagedPhotoPreview: UIImage?
    @State private var createdPhotoTarget: StudyCard?
    @State private var showingCamera = false
    @State private var errorMessage: String?
    @State private var independentImageAction: IndependentImageAction?
    @Environment(\.dismiss) private var dismiss

    init(
        store: StudyStore,
        player: StudyAudioPlayer,
        card: StudyCard?,
        serverDraft: StudyManualCardDraft?,
        timeStore: StudyTimeStore? = nil
    ) {
        self.store = store
        self.player = player
        self.card = card
        self.serverDraft = serverDraft
        self.timeStore = timeStore
        let initialDraft = if let card {
            StudyCardDraft(card: card)
        } else if let serverDraft {
            StudyCardDraft(manualDraft: serverDraft)
        } else {
            StudyCardDraft()
        }
        _draft = State(initialValue: initialDraft)
        _clientDraftID = State(initialValue: serverDraft?.id ?? ClientIdentifier.ulid())
        _creationKind = State(initialValue: serverDraft?.creationKind ?? .textRecognition)
        _previewAudio = State(initialValue: serverDraft?.previewAudio)
        _previewAudioRole = State(initialValue: serverDraft?.previewAudioRole)
        _previewImage = State(initialValue: serverDraft?.previewImage)
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    if card == nil {
                        Section("Card type") {
                            Picker("Card type", selection: $creationKind) {
                                ForEach(StudyCardCreationKind.allCases) { kind in
                                    Text(kind.title).tag(kind)
                                }
                            }
                            .disabled(serverDraft != nil)
                            .onChange(of: creationKind) { _, kind in
                                applyCreationKind(kind)
                            }
                            if serverDraft == nil,
                               [.audioRecognition, .productionImage].contains(creationKind)
                            {
                                Label(
                                    "This mode uses learning-os to prepare generated media before you create the card.",
                                    systemImage: "network"
                                )
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if draft.cardType == .cloze {
                        clozeFields
                    } else {
                        standardFields
                    }

                    imageFields
                    answerAudioFields

                    Section("Notes") {
                        TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                            .lineLimit(2...6)
                    }
                }
                .disabled(isDraftCommitPending)

                if card?.mediaURLs.isEmpty == false {
                    Section {
                        Label(
                            "Existing media stays offline. Image placement controls which faces show the image.",
                            systemImage: "photo.on.rectangle.angled"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
                if card != nil {
                    Section {
                        Button("Delete Card", role: .destructive) {
                            Task { await deleteCard() }
                        }
                        .disabled(isBusy)
                    }
                } else if serverDraft != nil {
                    Section {
                        Button("Delete Draft", role: .destructive) {
                            Task { await deleteServerDraft() }
                        }
                        .disabled(isBusy || isDraftCommitPending)
                        if serverDraft.map({
                            store.hasPendingDraftCommit(for: $0.id)
                        }) == true {
                            Text(
                                isDraftCleanupPending
                                    ? "The card was created. Retry Create Card or sync to finish cleanup."
                                    : isDraftCommitRejected
                                    ? "The previous commit was rejected. Edit and retry with the same card ID, or delete this draft."
                                    : "The commit outcome is unknown. Editing is locked; retry Create Card or sync."
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(
                card != nil ? "Edit Card" : serverDraft != nil ? "Review Draft" : "New Card"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveButtonTitle) {
                        if draft.isReplacingIndependentFaceImages {
                            independentImageAction = .save
                        } else {
                            Task { await save() }
                        }
                    }
                    .disabled(!draft.isValid(for: creationKind) || isBusy)
                }
            }
            .task(id: card?.id) {
                await loadCurrentMedia()
            }
            .onAppear {
                startTimeTracking()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    startTimeTracking()
                } else {
                    timeStore?.stop(activity: .cardCreation, source: .automatic)
                }
            }
            .onChange(of: store.manualDrafts.map(\.id)) { _, draftIDs in
                guard let serverDraft else { return }
                if !draftIDs.contains(serverDraft.id),
                   !store.hasPendingDraftCommit(for: serverDraft.id)
                {
                    dismiss()
                }
            }
            .onDisappear {
                timeStore?.stop(activity: .cardCreation, source: .automatic)
                audioRegenerationTask?.cancel()
                audioRegenerationTask = nil
                imageRegenerationTask?.cancel()
                imageRegenerationTask = nil
                if player.isCurrent(answerAudioTrackID) {
                    player.stop()
                }
            }
            .sheet(isPresented: $showingCamera) {
                CameraImagePicker { image in
                    stagePhoto(image)
                }
                .ignoresSafeArea()
            }
            .alert(item: $independentImageAction) { action in
                Alert(
                    title: Text("Replace distinct front and back images?"),
                    message: Text(
                        action == .save
                            ? "Saving this placement converts the card to one image and removes the other face’s distinct image."
                            : "Regenerating converts this card to one generated image using the selected placement."
                    ),
                    primaryButton: .destructive(
                        Text(action == .save ? "Save and Replace" : "Replace Images")
                    ) {
                        if action == .save {
                            Task { await save() }
                        } else {
                            startImageRegeneration()
                        }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    private var isBusy: Bool {
        isSaving || isRegeneratingAudio || isRegeneratingImage
    }

    private func startTimeTracking() {
        timeStore?.start(
            activity: .cardCreation,
            source: .automatic,
            name: "Card creator"
        )
    }

    private var isDraftCommitPending: Bool {
        serverDraft.map {
            let state = store.draftCommitRecoveryState(for: $0.id)
            return state == .outcomeUnknown || state == .cleanupPending
        } == true
    }

    private var isDraftCleanupPending: Bool {
        serverDraft.map {
            store.draftCommitRecoveryState(for: $0.id) == .cleanupPending
        } == true
    }

    private var isDraftCommitRejected: Bool {
        serverDraft.map {
            store.draftCommitRecoveryState(for: $0.id) == .rejected
        } == true
    }

    private var saveButtonTitle: String {
        if serverDraft != nil {
            return "Create Card"
        }
        if [.audioRecognition, .productionImage].contains(creationKind) {
            return "Prepare"
        }
        return "Save"
    }

    private func applyCreationKind(_ kind: StudyCardCreationKind) {
        draft.cardType = kind.cardType
        draft.isAudioLedPrompt = kind == .audioRecognition
        draft.isMediaLedPrompt = kind == .audioRecognition || kind == .productionImage
        draft.imagePlacement = kind.defaultImagePlacement
        if kind.defaultImagePlacement == .none {
            draft.imagePrompt = ""
            draft.currentImage = nil
        }
        previewAudio = nil
        previewAudioRole = nil
        previewImage = nil
        answerAudioLocalURL = nil
        promptImageLocalURL = nil
        answerImageLocalURL = nil
        promptImagePreview = nil
        answerImagePreview = nil
    }

    @ViewBuilder
    private var imageFields: some View {
        Section("Image") {
            if let stagedPhotoPreview {
                imagePreview(stagedPhotoPreview, label: "Selected photo")
            }
            if let promptImagePreview {
                imagePreview(
                    promptImagePreview,
                    label: answerImageLocalURL == promptImageLocalURL
                        ? "Current card image"
                        : "Front image"
                )
            }
            if
                let answerImagePreview,
                answerImageLocalURL != promptImageLocalURL
            {
                imagePreview(answerImagePreview, label: "Back image")
            } else if card != nil {
                if promptImagePreview == nil {
                    Text("No current image")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Image prompt")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(
                    "Describe the image to generate",
                    text: $draft.imagePrompt,
                    axis: .vertical
                )
                .lineLimit(2...6)
                .disabled(isRegeneratingImage)
                Text(
                    "\(draft.imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines).count)/1,000"
                )
                    .font(.caption)
                    .foregroundStyle(
                        draft.imagePrompt.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).count > 1_000 ? .red : .secondary
                    )
            }

            Picker("Image placement", selection: $draft.imagePlacement) {
                ForEach(StudyCardDraft.ImagePlacement.allCases) { placement in
                    Text(placement.title).tag(placement)
                }
            }
            .disabled(isRegeneratingImage)
            .onChange(of: draft.imagePlacement) { _, placement in
                applyImagePlacementPreview(placement)
            }

            if supportsUserPhoto {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                }
                .onChange(of: selectedPhotoItem) { _, item in
                    guard let item else { return }
                    Task {
                        do {
                            guard
                                let data = try await item.loadTransferable(type: Data.self),
                                let image = UIImage(data: data)
                            else {
                                throw CocoaError(.fileReadCorruptFile)
                            }
                            stagePhoto(image)
                        } catch {
                            errorMessage = "The selected photo could not be loaded."
                        }
                    }
                }

                Button {
                    showingCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                if stagedPhotoData != nil {
                    Button("Remove Selected Photo", role: .destructive) {
                        stagedPhotoData = nil
                        stagedPhotoPreview = nil
                        selectedPhotoItem = nil
                    }
                    Text("The selected photo will upload when you save the card.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if card != nil || serverDraft != nil {
                Button {
                    if draft.hasIndependentFaceImages {
                        independentImageAction = .regenerate
                    } else {
                        startImageRegeneration()
                    }
                } label: {
                    if isRegeneratingImage {
                        Label("Regenerating image…", systemImage: "photo.badge.arrow.down")
                    } else {
                        Label("Regenerate Image", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(
                    isBusy
                        || draft.imagePlacement == .none
                        || draft.imagePrompt.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                        || draft.imagePrompt.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).count > 1_000
                )
            } else {
                Text(
                    creationKind == .productionImage
                        ? "Tap Prepare to let learning-os fill the draft before generating its image."
                        : "An image can be generated after this card has synced."
                )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func imagePreview(_ image: UIImage, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 220)
                .clipShape(.rect(cornerRadius: 12))
                .accessibilityLabel(label)
        }
    }

    @ViewBuilder
    private var answerAudioFields: some View {
        Section("Answer audio") {
            if card != nil || serverDraft != nil {
                if let answerAudioLocalURL {
                    Button {
                        if player.isCurrent(answerAudioTrackID), player.isPlaying {
                            player.stop()
                        } else {
                            player.play(
                                url: answerAudioLocalURL,
                                trackID: answerAudioTrackID
                            )
                        }
                    } label: {
                        Label(
                            player.isCurrent(answerAudioTrackID) && player.isPlaying
                                ? "Stop current audio"
                                : "Play current audio",
                            systemImage: player.isCurrent(answerAudioTrackID) && player.isPlaying
                                ? "stop.fill"
                                : "play.fill"
                        )
                    }
                    .disabled(player.isBlockedByLongFormAudio || isBusy)
                } else {
                    Text("No current audio")
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Voice", selection: $draft.answerAudioVoiceId) {
                if !StudyAnswerVoice.japanese.contains(
                    where: { $0.id == draft.answerAudioVoiceId }
                ) {
                    Text("Current voice").tag(draft.answerAudioVoiceId)
                }
                ForEach(StudyAnswerVoice.japanese) { voice in
                    Text("\(voice.name) — \(voice.detail)").tag(voice.id)
                }
            }

            TextField(
                "Phonetic audio override (optional)",
                text: $draft.answerAudioTextOverride,
                axis: .vertical
            )
            .lineLimit(1...4)

            if card != nil || serverDraft != nil {
                Button {
                    audioRegenerationTask?.cancel()
                    audioRegenerationTask = Task {
                        await regenerateAnswerAudio()
                    }
                } label: {
                    if isRegeneratingAudio {
                        Label("Regenerating audio…", systemImage: "waveform")
                    } else {
                        Label("Regenerate Audio", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isBusy)
            } else {
                Text(
                    creationKind == .audioRecognition
                        ? "Tap Prepare to let learning-os fill the draft before generating its prompt audio."
                        : "Audio can be generated after this card has synced."
                )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var standardFields: some View {
        if draft.isAudioLedPrompt {
            Section("Prompt") {
                Label(
                    creationKind == .audioRecognition && card == nil
                        ? "This card uses generated audio as the prompt."
                        : "This card uses its existing audio or image as the prompt.",
                    systemImage: "play.rectangle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } else {
            Section("Prompt") {
                TextField("Japanese prompt", text: $draft.cueText, axis: .vertical)
                TextField("Prompt reading (optional)", text: $draft.cueReading, axis: .vertical)
                TextField("Prompt hint (optional)", text: $draft.cueMeaning, axis: .vertical)
            }
        }
        Section("Answer") {
            TextField("Japanese answer", text: $draft.answerExpression, axis: .vertical)
            TextField("Answer reading (optional)", text: $draft.answerReading, axis: .vertical)
            TextField("Meaning (optional)", text: $draft.answerMeaning, axis: .vertical)
                .lineLimit(2...6)
            TextField("Japanese example (optional)", text: $draft.sentenceJapanese, axis: .vertical)
                .lineLimit(2...6)
            TextField("English example (optional)", text: $draft.sentenceEnglish, axis: .vertical)
                .lineLimit(2...6)
        }
    }

    @ViewBuilder
    private var clozeFields: some View {
        Section("Prompt") {
            TextField("Cloze text", text: $draft.cueText, axis: .vertical)
                .lineLimit(2...6)
            Text("Use Anki-style markup, for example: 毎日{{c1::勉強する}}。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !draft.cueText.isEmpty, !draft.hasCanonicalClozeMarkup {
                Text("Add a cloze marker such as {{c1::answer}} before saving.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            TextField("Hint (optional)", text: $draft.cueMeaning, axis: .vertical)
        }
        Section("Answer") {
            TextField("Restored sentence", text: $draft.answerExpression, axis: .vertical)
                .lineLimit(2...6)
            TextField("Sentence with furigana (optional)", text: $draft.answerReading, axis: .vertical)
                .lineLimit(2...6)
            TextField("Meaning (optional)", text: $draft.answerMeaning, axis: .vertical)
                .lineLimit(2...6)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            var didCreateCard = false
            var photoTarget = createdPhotoTarget
            if let card {
                try await store.updateCard(card, draft: draft)
                photoTarget = card
            } else if createdPhotoTarget != nil {
                // Card creation already succeeded on an earlier save attempt.
                // Retry only the photo upload so a transient failure cannot
                // create a second card with a new client identifier.
            } else if let serverDraft {
                try await store.createCard(
                    from: serverDraft,
                    draft: draft,
                    previewAudio: previewAudio,
                    previewAudioRole: previewAudioRole,
                    previewImage: previewImage
                )
                didCreateCard = true
            } else if [.audioRecognition, .productionImage].contains(creationKind) {
                try await store.queueManualDraft(
                    creationKind: creationKind,
                    draft: draft,
                    id: clientDraftID
                )
            } else {
                photoTarget = try await store.createCard(draft)
                createdPhotoTarget = photoTarget
                didCreateCard = true
            }
            if let stagedPhotoData, let photoTarget {
                _ = try await store.uploadImage(
                    for: photoTarget,
                    jpegData: stagedPhotoData,
                    placement: draft.imagePlacement
                )
            }
            if didCreateCard {
                timeStore?.addCreatedCards()
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var supportsUserPhoto: Bool {
        serverDraft == nil
            && (card != nil
                || ![.audioRecognition, .productionImage].contains(creationKind))
    }

    private func stagePhoto(_ image: UIImage) {
        let maxDimension: CGFloat = 2_048
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = normalized.jpegData(compressionQuality: 0.85) else {
            errorMessage = "The selected photo could not be prepared."
            return
        }
        stagedPhotoData = data
        stagedPhotoPreview = normalized
        if draft.imagePlacement == .none {
            draft.imagePlacement = .answer
        }
        errorMessage = nil
    }

    private func deleteCard() async {
        guard let card else { return }
        do {
            try await store.deleteCard(card)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteServerDraft() async {
        guard let serverDraft else { return }
        do {
            try await store.deleteManualDraft(serverDraft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var answerAudioTrackID: String {
        "card-editor-answer-\(card?.id ?? serverDraft?.id ?? "new")"
    }

    private func loadCurrentAnswerAudio() async {
        let remoteURL = card?.audioURL ?? previewAudio?.mediaURLs.first
        guard let remoteURL else {
            answerAudioLocalURL = nil
            return
        }
        answerAudioLocalURL = await store.playableMediaURL(for: remoteURL)
    }

    private func loadCurrentMedia() async {
        await loadCurrentAnswerAudio()
        let draftImageURL = previewImage?.mediaURLs.first
        let promptURL = card?.promptImageURL
            ?? (draft.imagePlacement.includesPrompt ? draftImageURL : nil)
        let answerURL = card?.answerImageURL
            ?? (draft.imagePlacement.includesAnswer ? draftImageURL : nil)
        if let promptURL {
            promptImageLocalURL = await store.playableMediaURL(for: promptURL)
            promptImagePreview = promptImageLocalURL.flatMap {
                UIImage(contentsOfFile: $0.path)
            }
        } else {
            promptImageLocalURL = nil
            promptImagePreview = nil
        }
        originalPromptImageLocalURL = promptImageLocalURL
        originalPromptImagePreview = promptImagePreview
        if let answerURL {
            answerImageLocalURL = await store.playableMediaURL(for: answerURL)
            answerImagePreview = if answerImageLocalURL == promptImageLocalURL {
                promptImagePreview
            } else {
                answerImageLocalURL.flatMap {
                    UIImage(contentsOfFile: $0.path)
                }
            }
        } else {
            answerImageLocalURL = nil
            answerImagePreview = nil
        }
        originalAnswerImageLocalURL = answerImageLocalURL
        originalAnswerImagePreview = answerImagePreview
        sharedImageLocalURL = promptImageLocalURL ?? answerImageLocalURL
        sharedImagePreview = promptImagePreview ?? answerImagePreview
    }

    private func applyImagePlacementPreview(
        _ placement: StudyCardDraft.ImagePlacement
    ) {
        if draft.hasIndependentFaceImages {
            switch placement {
            case .answer:
                sharedImageLocalURL =
                    originalAnswerImageLocalURL ?? originalPromptImageLocalURL
                sharedImagePreview =
                    originalAnswerImagePreview ?? originalPromptImagePreview
            case .none, .prompt, .both:
                sharedImageLocalURL =
                    originalPromptImageLocalURL ?? originalAnswerImageLocalURL
                sharedImagePreview =
                    originalPromptImagePreview ?? originalAnswerImagePreview
            }
        }
        switch placement {
        case .none:
            promptImageLocalURL = nil
            answerImageLocalURL = nil
            promptImagePreview = nil
            answerImagePreview = nil
        case .prompt:
            promptImageLocalURL = sharedImageLocalURL
            answerImageLocalURL = nil
            promptImagePreview = sharedImagePreview
            answerImagePreview = nil
        case .answer:
            promptImageLocalURL = nil
            answerImageLocalURL = sharedImageLocalURL
            promptImagePreview = nil
            answerImagePreview = sharedImagePreview
        case .both:
            promptImageLocalURL = sharedImageLocalURL
            answerImageLocalURL = sharedImageLocalURL
            promptImagePreview = sharedImagePreview
            answerImagePreview = sharedImagePreview
        }
    }

    private func startImageRegeneration() {
        imageRegenerationTask?.cancel()
        imageRegenerationTask = Task {
            await regenerateImage()
        }
    }

    private func regenerateAnswerAudio() async {
        isRegeneratingAudio = true
        errorMessage = nil
        defer { isRegeneratingAudio = false }
        do {
            if let serverDraft {
                let result = try await store.generateManualDraftPreviewAudio(
                    serverDraft,
                    draft: draft,
                    previewImage: previewImage
                )
                try Task.checkCancellation()
                previewAudio = result.draft.previewAudio
                previewAudioRole = result.draft.previewAudioRole
                if let localURL = result.localURL {
                    answerAudioLocalURL = localURL
                    player.stop()
                    player.play(url: localURL, trackID: answerAudioTrackID)
                }
                return
            }
            guard let card else { return }
            let result = try await store.regenerateAnswerAudio(
                for: card,
                voiceID: draft.answerAudioVoiceId,
                textOverride: draft.answerAudioTextOverride
            )
            try Task.checkCancellation()
            answerAudioLocalURL = result.localURL
            player.stop()
            player.play(url: result.localURL, trackID: answerAudioTrackID)
        } catch is CancellationError {
            // The store still reconciles completed server/cache side effects,
            // but a dismissed editor must not update UI or begin playback.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func regenerateImage() async {
        isRegeneratingImage = true
        errorMessage = nil
        defer { isRegeneratingImage = false }
        do {
            if let serverDraft {
                let result = try await store.generateManualDraftPreviewImage(
                    serverDraft,
                    draft: draft,
                    previewAudio: previewAudio,
                    previewAudioRole: previewAudioRole
                )
                try Task.checkCancellation()
                previewImage = result.draft.previewImage
                draft.imagePrompt = result.draft.imagePrompt ?? draft.imagePrompt
                draft.reconcileImages(
                    promptImage: result.draft.imagePlacement.includesPrompt
                        ? result.draft.previewImage : nil,
                    answerImage: result.draft.imagePlacement.includesAnswer
                        ? result.draft.previewImage : nil
                )
                let generatedImagePreview = UIImage(contentsOfFile: result.localURL.path)
                sharedImageLocalURL = result.localURL
                sharedImagePreview = generatedImagePreview
                applyImagePlacementPreview(result.draft.imagePlacement)
                originalPromptImageLocalURL = promptImageLocalURL
                originalPromptImagePreview = promptImagePreview
                originalAnswerImageLocalURL = answerImageLocalURL
                originalAnswerImagePreview = answerImagePreview
                return
            }
            guard let card else { return }
            let result = try await store.regenerateImage(
                for: card,
                prompt: draft.imagePrompt,
                placement: draft.imagePlacement
            )
            try Task.checkCancellation()
            let requestedPlacement = draft.imagePlacement
            let nextPromptImageLocalURL: URL?
            if let promptURL = result.card.promptImageURL {
                nextPromptImageLocalURL = requestedPlacement.includesPrompt
                    ? result.localURL
                    : await store.playableMediaURL(for: promptURL)
            } else {
                nextPromptImageLocalURL = nil
            }
            let nextAnswerImageLocalURL: URL?
            if let answerURL = result.card.answerImageURL {
                nextAnswerImageLocalURL = requestedPlacement.includesAnswer
                    ? result.localURL
                    : await store.playableMediaURL(for: answerURL)
            } else {
                nextAnswerImageLocalURL = nil
            }
            try Task.checkCancellation()
            let generatedImagePreview = UIImage(contentsOfFile: result.localURL.path)
            let nextPromptImagePreview = if nextPromptImageLocalURL == result.localURL {
                generatedImagePreview
            } else {
                nextPromptImageLocalURL.flatMap {
                    UIImage(contentsOfFile: $0.path)
                }
            }
            let nextAnswerImagePreview = if nextAnswerImageLocalURL == result.localURL {
                generatedImagePreview
            } else if nextAnswerImageLocalURL == nextPromptImageLocalURL {
                nextPromptImagePreview
            } else {
                nextAnswerImageLocalURL.flatMap {
                    UIImage(contentsOfFile: $0.path)
                }
            }
            draft.reconcileImages(
                promptImage: result.card.prompt["cueImage"],
                answerImage: result.card.answer["answerImage"]
            )
            sharedImageLocalURL = result.localURL
            sharedImagePreview = generatedImagePreview
            promptImageLocalURL = nextPromptImageLocalURL
            promptImagePreview = nextPromptImagePreview
            answerImageLocalURL = nextAnswerImageLocalURL
            answerImagePreview = nextAnswerImagePreview
            originalPromptImageLocalURL = promptImageLocalURL
            originalPromptImagePreview = promptImagePreview
            originalAnswerImageLocalURL = answerImageLocalURL
            originalAnswerImagePreview = answerImagePreview
        } catch is CancellationError {
            // Completed server/cache work is reconciled by StudyStore.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
