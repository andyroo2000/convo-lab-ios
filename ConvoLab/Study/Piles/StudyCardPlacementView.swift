import SwiftUI

struct StudyCardPlacementView: View {
    let store: StudyStore
    let cardID: String
    @State private var card: StudyCardPlacementSnapshot?
    @State private var source: StudyBookSource?
    @State private var learnSoon = false
    @State private var order = ""
    @State private var busy = false
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                if card != nil {
                    Section("Card source") {
                        StudyBookSourceFields(store: store, source: $source)
                        if source != nil { TextField("Order within chapter (optional)", text: $order).keyboardType(.numberPad) }
                        if !validOrder { Text("Order must be a whole number from 0 to 1,000,000.").foregroundStyle(.red) }
                        Button("Save source") { Task { await saveSource() } }.disabled(!validOrder)
                    }
                    if card?.state.queueState == "new" {
                        Section("Priority") {
                            Toggle("Learn soon", isOn: $learnSoon)
                            Text("Reserve a share of new cards for this item. Paused books and chapters stay paused.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Save priority") { Task { await savePriority() } }
                        }
                    }
                }
                if busy { ProgressView() }
                if saved { Label("Saved", systemImage: "checkmark.circle").foregroundStyle(.green) }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Reload card") { Task { await load() } }
                }
            }
            .disabled(busy)
            .navigationTitle("Source and priority")
            .onChange(of: source) { old, new in
                saved = false
                if old?.pileId != new?.pileId { order = new?.position.map(String.init) ?? "" }
            }
            .onChange(of: learnSoon) { _, _ in saved = false }
            .onChange(of: order) { _, _ in saved = false }
            .task { await load() }
        }
    }

    private var validOrder: Bool { order.isEmpty || Int(order).map { (0...1_000_000).contains($0) } == true }

    private func load() async {
        await perform {
            let snapshot = try await store.cardPlacement(id: cardID)
            card = snapshot
            source = snapshot.bookSource
            learnSoon = snapshot.learnSoon ?? false
            order = snapshot.bookSource?.position.map(String.init) ?? ""
            await store.refreshPiles()
        }
    }

    private func saveSource() async {
        await perform {
            source?.position = Int(order)
            try await store.assignCardSource(id: cardID, source: source)
            saved = true
        }
    }

    private func savePriority() async {
        await perform {
            try await store.assignLearnSoon(id: cardID, value: learnSoon)
            saved = true
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        error = nil
        saved = false
        defer { busy = false }
        do { try await operation() }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
