import SwiftUI

struct StudyPileToggleRow: View {
    let store: StudyStore
    let item: StudyPileChapter
    var pileID: String?
    @State private var savedActive: Bool?
    @State private var saving = false
    @State private var error: String?
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { savedActive ?? item.isActive }, set: { active in save(active) })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.headline)
                    Text("\(item.readyCount) ready · \(item.newCount) remaining · \(item.introducedCount) introduced")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(saving)
            .tint(ConvoLabTheme.cyan)
            .onChange(of: item.isActive) { _, _ in savedActive = nil }
            .onChange(of: store.piles.isRefreshing) { _, refreshing in
                if !refreshing && store.piles.errorMessage == nil { savedActive = nil }
            }
            .accessibilityLabel("Include \(item.title) in new cards")
            .accessibilityValue("\(item.readyCount) ready, \(item.newCount) remaining")
            Button("Edit title and order") { editing = true }
                .font(.caption).frame(minHeight: 44)
            if saving { ProgressView() }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red) }
        }
        .sheet(isPresented: $editing) {
            StudyPileEditView(store: store, item: item, pileID: pileID)
        }
    }

    private func save(_ active: Bool) {
        guard !saving else { return }
        saving = true
        error = nil
        savedActive = active
        Task {
            defer { saving = false }
            do { try await store.savePile(id: item.id, update: StudyPileUpdate(isActive: active), pileID: pileID) }
            catch { savedActive = nil; self.error = error.localizedDescription }
        }
    }
}
