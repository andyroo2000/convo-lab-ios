import SwiftUI

struct JournalEntryView: View {
    @State private var model: JournalEntryModel
    let knownKanji: Set<Character>
    @State private var copiedID: String?

    init(id: String, store: JournalStore, knownKanji: Set<Character>) {
        _model = State(initialValue: JournalEntryModel(id: id, store: store))
        self.knownKanji = knownKanji
    }

    private var isReviewing: Bool { model.analysis?.status == .ready && !model.isEditing }
    private var pollingKey: String { "\(model.analysis?.id ?? ""):\(model.analysis?.status.rawValue ?? ""):\(model.analysis?.pendingReplyId ?? "")" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let message = model.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
                if model.hasConflict {
                    Button("Save as a new entry") {
                        do { copiedID = try model.copyAsNew() }
                        catch { model.errorMessage = "Could not preserve a separate copy. Keep this entry open." }
                    }
                }
                if isReviewing { review } else { JournalEntryForm(model: model) }
                if model.analysis?.status.isPending == true { ProgressView("Preparing feedback…") }
                if model.analysis?.status == .failed {
                    Text(model.analysis?.error ?? "Feedback could not be prepared. Try Submit again.").foregroundStyle(.red)
                }
            }.padding(20)
        }
        .paperBackground()
        .navigationTitle("Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await model.load() }
        .task(id: pollingKey) { await model.poll() }
        .navigationDestination(item: $copiedID) { id in
            JournalEntryView(id: id, store: model.store, knownKanji: knownKanji)
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(model.draft?.entryDate ?? "").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Edit entry") { model.isEditing = true }
            }
            Text(model.draft?.title ?? "Untitled entry").font(.largeTitle.bold()).foregroundStyle(ConvoLabTheme.navy)
            Text(model.draft?.body ?? "").font(.title3).textSelection(.enabled)
            Divider()
            HStack {
                Text("Corrected Version").font(.headline)
                Spacer()
                Button("Copy") { UIPasteboard.general.string = model.analysis?.correctedText }
            }
            StudyRubyText(model.analysis?.correctedReading ?? "", knownKanji: knownKanji, pointSize: 20, alignment: .left)
        }
    }
}
