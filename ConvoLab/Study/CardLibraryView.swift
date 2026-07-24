import SwiftUI

struct CardLibraryView: View {
    let store: StudyStore
    @State private var showingCreate = false
    @State private var selectedCard: StudyCard?

    var body: some View {
        NavigationStack {
            List(store.libraryCards) { card in
                Button {
                    selectedCard = card
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.promptText)
                            .font(.headline)
                            .foregroundStyle(ConvoLabTheme.navy)
                        Text(card.answerText)
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
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
                CardEditorView(store: store, card: nil)
            }
            .sheet(item: $selectedCard) { card in
                CardEditorView(store: store, card: card)
            }
        }
    }
}

private struct CardEditorView: View {
    let store: StudyStore
    let card: StudyCard?

    @State private var expression: String
    @State private var reading: String
    @State private var meaning: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(store: StudyStore, card: StudyCard?) {
        self.store = store
        self.card = card
        _expression = State(initialValue: card?.promptText ?? "")
        _reading = State(initialValue: "")
        _meaning = State(initialValue: card?.answerText ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Japanese") {
                    TextField("Expression", text: $expression)
                    TextField("Reading (optional)", text: $reading)
                }
                Section("Answer") {
                    TextField("Meaning", text: $meaning, axis: .vertical)
                        .lineLimit(2...6)
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
                    .disabled(expression.isEmpty || meaning.isEmpty || isSaving)
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            if let card {
                try await store.updateCard(card, prompt: expression, answer: meaning)
            } else {
                try await store.createCard(
                    expression: expression,
                    reading: reading,
                    meaning: meaning
                )
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
}
