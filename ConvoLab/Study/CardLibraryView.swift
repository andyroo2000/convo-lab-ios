import SwiftUI

struct CardLibraryView: View {
    let store: StudyStore
    let player: StudyAudioPlayer
    @State private var showingCreate = false
    @State private var selectedCard: StudyCard?
    @State private var showingDeletionError = false
    @State private var deletionErrorMessage = ""

    var body: some View {
        NavigationStack {
            List(store.libraryCards) { card in
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
            }
            .overlay {
                if store.libraryCards.isEmpty {
                    ContentUnavailableView(
                        "No local cards",
                        systemImage: "rectangle.stack",
                        description: Text("Sync or create a card to begin.")
                    )
                }
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
            }
            .sheet(isPresented: $showingCreate) {
                CardEditorView(store: store, player: player, card: nil)
            }
            .sheet(item: $selectedCard) { card in
                CardEditorView(store: store, player: player, card: card)
            }
            .alert("Could not delete card", isPresented: $showingDeletionError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deletionErrorMessage)
            }
        }
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

private struct CardEditorView: View {
    let store: StudyStore
    let player: StudyAudioPlayer
    let card: StudyCard?

    @State private var draft: StudyCardDraft
    @State private var isSaving = false
    @State private var isRegeneratingAudio = false
    @State private var regenerationTask: Task<Void, Never>?
    @State private var answerAudioLocalURL: URL?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(store: StudyStore, player: StudyAudioPlayer, card: StudyCard?) {
        self.store = store
        self.player = player
        self.card = card
        _draft = State(initialValue: card.map(StudyCardDraft.init(card:)) ?? StudyCardDraft())
    }

    var body: some View {
        NavigationStack {
            Form {
                if card == nil {
                    Section("Card type") {
                        Picker("Card type", selection: $draft.cardType) {
                            ForEach(StudyCardDraft.CardType.allCases) { type in
                                Text(type.title).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if draft.cardType == .cloze {
                    clozeFields
                } else {
                    standardFields
                }

                answerAudioFields

                Section("Notes") {
                    TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                if card?.mediaURLs.isEmpty == false {
                    Section {
                        Label(
                            "Existing audio and images are preserved when you save.",
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
                        .disabled(isSaving || isRegeneratingAudio)
                    }
                }
            }
            .navigationTitle(card == nil ? "New Card" : "Edit Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(!draft.isValid || isSaving || isRegeneratingAudio)
                }
            }
            .task(id: card?.id) {
                await loadCurrentAnswerAudio()
            }
            .onDisappear {
                regenerationTask?.cancel()
                regenerationTask = nil
                if player.isCurrent(answerAudioTrackID) {
                    player.stop()
                }
            }
        }
    }

    @ViewBuilder
    private var answerAudioFields: some View {
        Section("Answer audio") {
            if card != nil {
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
                    .disabled(player.isBlockedByLongFormAudio)
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

            if card != nil {
                Button {
                    regenerationTask?.cancel()
                    regenerationTask = Task {
                        await regenerateAnswerAudio()
                    }
                } label: {
                    if isRegeneratingAudio {
                        Label("Regenerating audio…", systemImage: "waveform")
                    } else {
                        Label("Regenerate Audio", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isSaving || isRegeneratingAudio)
            } else {
                Text("Audio can be generated after this card has synced.")
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
                    "This card uses its existing audio or image as the prompt.",
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
            if let card {
                try await store.updateCard(card, draft: draft)
            } else {
                try await store.createCard(draft)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
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

    private var answerAudioTrackID: String {
        "card-editor-answer-\(card?.id ?? "new")"
    }

    private func loadCurrentAnswerAudio() async {
        guard
            let remoteURL = card?.answerAudioURL
        else {
            answerAudioLocalURL = nil
            return
        }
        answerAudioLocalURL = await store.playableMediaURL(for: remoteURL)
    }

    private func regenerateAnswerAudio() async {
        guard let card else { return }
        isRegeneratingAudio = true
        errorMessage = nil
        defer { isRegeneratingAudio = false }
        do {
            let result = try await store.regenerateAnswerAudio(
                for: card,
                voiceID: draft.answerAudioVoiceId,
                textOverride: draft.answerAudioTextOverride
            )
            answerAudioLocalURL = result.localURL
            player.stop()
            player.play(url: result.localURL, trackID: answerAudioTrackID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
