import SwiftUI

struct StudyLearningPathEditorSection: View {
    let store: StudyStore
    let card: StudyCard

    @State private var path: StudyLearningPath?
    @State private var hasRequestedPath = false
    @State private var searchText = ""
    @State private var searchResults: [StudyCard] = []
    @State private var selectedSuccessor: StudyCard?
    @State private var unlockRequirement: StudyLearningPathUnlockRequirement = .guru
    @State private var isLoading = false
    @State private var isSearching = false
    @State private var isLinking = false
    @State private var didSearch = false
    @State private var linkedSuccess = false
    @State private var errorMessage: String?

    var body: some View {
        Section("Learning path") {
            Text("Make this card unlock another card after a chosen level of mastery.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !hasRequestedPath {
                Button {
                    hasRequestedPath = true
                    Task { await loadPath() }
                } label: {
                    Label("View or edit learning path", systemImage: "point.3.connected.trianglepath.dotted")
                }
            } else if isLoading, path == nil {
                ProgressView("Loading path…")
            } else if let path {
                if path.stages.isEmpty {
                    Text("This card can start a new path.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(path.stages) { stage in
                        stageView(stage)
                    }
                }

                if isTail(path) {
                    successorEditor(path)
                } else if let tailCard = path.stages.last?.cards.last {
                    Label(
                        "Only the last card can extend this path. Edit \(tailCard.displayText) to add another stage.",
                        systemImage: "arrow.right.to.line"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            if linkedSuccess {
                Label("Next card linked.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
    }

    private func stageView(_ stage: StudyLearningPathStage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stage.number.map { "Stage \($0)" } ?? "Stage")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(stage.cards) { pathCard in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pathCard.displayText)
                            .foregroundStyle(ConvoLabTheme.navy)
                        if let meaning = pathCard.meaning {
                            Text(meaning)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        if StudyCardIdentity.matches(card, any: [pathCard.id]) {
                            Text("Current")
                                .font(.caption2.weight(.semibold))
                        }
                        if let requirement = pathCard.variantUnlockRequirement {
                            Text(requirement.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func successorEditor(_ path: StudyLearningPath) -> some View {
        TextField("Search for the next card", text: $searchText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit { Task { await search(path: path) } }

        Button {
            Task { await search(path: path) }
        } label: {
            if isSearching {
                ProgressView()
            } else {
                Label("Find Card", systemImage: "magnifyingglass")
            }
        }
        .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)

        if didSearch, searchResults.isEmpty, !isSearching {
            Text("No eligible cards found.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        ForEach(searchResults) { result in
            Button {
                selectedSuccessor = result
                unlockRequirement = Self.defaultRequirement(for: result)
                linkedSuccess = false
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.promptText)
                            .foregroundStyle(ConvoLabTheme.navy)
                        Text(result.answerText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedSuccessor.map({ StudyCardIdentity.matches($0, result) }) == true {
                        Image(systemName: "checkmark.circle.fill")
                    }
                }
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(.plain)
        }

        if let selectedSuccessor {
            Picker("Unlock next card", selection: $unlockRequirement) {
                ForEach(StudyLearningPathUnlockRequirement.selectableCases, id: \.self) {
                    Text($0.title).tag($0)
                }
            }

            Text(unlockRequirement.helpText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                Task { await link(selectedSuccessor) }
            } label: {
                if isLinking {
                    ProgressView()
                } else {
                    Text("Link as Next Card")
                }
            }
            .disabled(isLinking)
        }
    }

    private func loadPath() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            path = try await store.learningPath(for: card)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func search(path: StudyLearningPath) async {
        isSearching = true
        didSearch = false
        errorMessage = nil
        linkedSuccess = false
        defer { isSearching = false }
        do {
            let pathIDs = Set(path.stages.flatMap(\.cards).map { $0.id.lowercased() })
            searchResults = try await store.searchLearningPathSuccessors(
                matching: searchText
            ).filter {
                !StudyCardIdentity.matches($0, card)
                    && !pathIDs.contains($0.reviewCardID.lowercased())
            }
            didSearch = true
        } catch is CancellationError {
            return
        } catch {
            searchResults = []
            errorMessage = error.localizedDescription
        }
    }

    private func link(_ successor: StudyCard) async {
        isLinking = true
        errorMessage = nil
        linkedSuccess = false
        defer { isLinking = false }
        do {
            path = try await store.linkLearningPathSuccessor(
                successor,
                to: card,
                requirement: unlockRequirement
            )
            searchText = ""
            searchResults = []
            selectedSuccessor = nil
            didSearch = false
            linkedSuccess = true
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isTail(_ path: StudyLearningPath) -> Bool {
        path.stages.isEmpty
            || path.stages.last?.cards.contains(where: {
                StudyCardIdentity.matches(card, any: [$0.id])
            }) == true
    }

    static func defaultRequirement(for card: StudyCard) -> StudyLearningPathUnlockRequirement {
        card.cardType == "cloze" || card.cardType == "production" ? .master : .guru
    }
}
