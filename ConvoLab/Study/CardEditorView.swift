import PhotosUI
import SwiftUI

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
    private let isRecoveringPendingCreate: Bool
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
        initialCreationKind: StudyCardCreationKind? = nil,
        initialDraft: StudyCardDraft? = nil,
        initialClientDraftID: String? = nil,
        timeStore: StudyTimeStore? = nil
    ) {
        self.store = store
        self.player = player
        self.card = card
        self.serverDraft = serverDraft
        self.timeStore = timeStore
        var resolvedInitialDraft = if let card {
            StudyCardDraft(
                card: card,
                defaultAnswerAudioVoiceID: store.capabilities.cardAuthoring
                    .defaultAnswerAudioVoiceId
            )
        } else if let serverDraft {
            StudyCardDraft(
                manualDraft: serverDraft,
                defaultAnswerAudioVoiceID: store.capabilities.cardAuthoring
                    .defaultAnswerAudioVoiceId
            )
        } else if let initialDraft {
            initialDraft
        } else {
            StudyCardDraft(
                defaultAnswerAudioVoiceID: store.capabilities.cardAuthoring
                    .defaultAnswerAudioVoiceId
            )
        }
        let advertisedCreationKinds = store.capabilities.cardAuthoring.creationKinds.compactMap(
            StudyCardCreationKind.init(rawValue:)
        )
        let requestedCreationKind = serverDraft?.creationKind
            ?? initialCreationKind
            ?? .textRecognition
        let resolvedCreationKind = Self.resolveCreationKind(
            requestedCreationKind,
            isEditingExistingCard: card != nil,
            preservesDraftKind: serverDraft != nil || initialDraft != nil,
            advertisedCreationKinds: advertisedCreationKinds
        )
        if card == nil, serverDraft == nil {
            resolvedInitialDraft.cardType = resolvedCreationKind.cardType
            resolvedInitialDraft.isAudioLedPrompt = resolvedCreationKind == .audioRecognition
            resolvedInitialDraft.isMediaLedPrompt = [.audioRecognition, .productionImage]
                .contains(resolvedCreationKind)
            resolvedInitialDraft.imagePlacement = resolvedCreationKind.defaultImagePlacement
        }
        _draft = State(initialValue: resolvedInitialDraft)
        _clientDraftID = State(
            initialValue: serverDraft?.id
                ?? initialClientDraftID
                ?? ClientIdentifier.ulid()
        )
        _creationKind = State(initialValue: resolvedCreationKind)
        _previewAudio = State(initialValue: serverDraft?.previewAudio)
        _previewAudioRole = State(initialValue: serverDraft?.previewAudioRole)
        _previewImage = State(initialValue: serverDraft?.previewImage)
        isRecoveringPendingCreate = card == nil
            && serverDraft == nil
            && initialDraft != nil
            && initialClientDraftID != nil
    }

    static func resolveCreationKind(
        _ requestedCreationKind: StudyCardCreationKind,
        isEditingExistingCard: Bool,
        preservesDraftKind: Bool,
        advertisedCreationKinds: [StudyCardCreationKind]
    ) -> StudyCardCreationKind {
        let preservesExistingKind = isEditingExistingCard || preservesDraftKind
        let canUseRequestedKind = preservesExistingKind
            || advertisedCreationKinds.isEmpty
            || advertisedCreationKinds.contains(requestedCreationKind)
        return canUseRequestedKind
            ? requestedCreationKind
            : advertisedCreationKinds[0]
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    if card == nil {
                        Section("Card type") {
                            Picker("Card type", selection: $creationKind) {
                                ForEach(availableCreationKinds) { kind in
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
                        CardEditorClozeFields(draft: $draft)
                    } else {
                        CardEditorStandardFields(
                            draft: $draft,
                            creationKind: creationKind,
                            isNewCard: card == nil
                        )
                    }

                    CardEditorImageSection(
                        draft: $draft,
                        selectedPhotoItem: $selectedPhotoItem,
                        stagedPhotoPreview: stagedPhotoPreview,
                        hasStagedPhoto: stagedPhotoData != nil,
                        promptImagePreview: promptImagePreview,
                        answerImagePreview: answerImagePreview,
                        promptImageLocalURL: promptImageLocalURL,
                        answerImageLocalURL: answerImageLocalURL,
                        hasExistingMediaTarget: card != nil || serverDraft != nil,
                        showsMissingCurrentImage: card != nil,
                        supportsUserPhoto: supportsUserPhoto,
                        creationKind: creationKind,
                        maximumPromptCharacters: store.capabilities.cardAuthoring.limits
                            .imagePromptCharacters,
                        availablePlacements: availableImagePlacements,
                        isRegeneratingImage: isRegeneratingImage,
                        isBusy: isBusy,
                        onStagePhoto: stagePhoto,
                        onPhotoLoadError: {
                            errorMessage = "The selected photo could not be loaded."
                        },
                        onRemovePhoto: {
                            stagedPhotoData = nil
                            stagedPhotoPreview = nil
                            selectedPhotoItem = nil
                        },
                        onTakePhoto: { showingCamera = true },
                        onPlacementChange: applyImagePlacementPreview,
                        onRegenerate: {
                            if draft.hasIndependentFaceImages {
                                independentImageAction = .regenerate
                            } else {
                                startImageRegeneration()
                            }
                        }
                    )
                    CardEditorAnswerAudioSection(
                        draft: $draft,
                        player: player,
                        answerAudioLocalURL: answerAudioLocalURL,
                        answerAudioTrackID: answerAudioTrackID,
                        hasExistingMediaTarget: card != nil || serverDraft != nil,
                        creationKind: creationKind,
                        isRegeneratingAudio: isRegeneratingAudio,
                        isBusy: isBusy,
                        onRegenerate: {
                            audioRegenerationTask?.cancel()
                            audioRegenerationTask = Task {
                                await regenerateAnswerAudio()
                            }
                        }
                    )

                    Section("Notes") {
                        TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                            .lineLimit(2...6)
                    }

                    if let card {
                        StudyLearningPathEditorSection(store: store, card: card)
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
                        .accessibilityIdentifier("card-editor-error")
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
                card != nil
                    ? "Edit Card"
                    : serverDraft != nil
                    ? "Review Draft"
                    : isRecoveringPendingCreate ? "Resume Draft" : "New Card"
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

    private var availableCreationKinds: [StudyCardCreationKind] {
        let advertised = store.capabilities.cardAuthoring.creationKinds.compactMap(
            StudyCardCreationKind.init(rawValue:)
        )
        return advertised.isEmpty ? StudyCardCreationKind.allCases : advertised
    }

    private var availableImagePlacements: [StudyCardDraft.ImagePlacement] {
        let advertised = store.capabilities.cardAuthoring.imagePlacements.compactMap(
            StudyCardDraft.ImagePlacement.init(rawValue:)
        )
        return advertised.isEmpty ? StudyCardDraft.ImagePlacement.allCases : advertised
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
