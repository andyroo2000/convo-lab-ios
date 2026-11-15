import SwiftUI

struct JournalConversationView: View {
    let root: JournalEntryModel
    let knownKanji: Set<Character>
    @State private var conversation: JournalConversationModel

    init(root: JournalEntryModel, knownKanji: Set<Character>) {
        self.root = root; self.knownKanji = knownKanji
        _conversation = State(initialValue: JournalConversationModel(root: root))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            JournalFeedbackView(model: root, knownKanji: knownKanji, followUp: false)
            if let error = conversation.errorMessage {
                Text(error).foregroundStyle(.red)
                Button("Retry conversation") { Task { await conversation.load() } }
            }
            if !conversation.loaded { ProgressView("Loading conversation…") }
            ForEach(conversation.nodes) { node in
                JournalConversationReply(node: node, root: root, knownKanji: knownKanji,
                                         last: node.id == conversation.nodes.last?.id, refresh: { await conversation.load() })
            }
            if conversation.loaded, conversation.nodes.isEmpty, let analysis = root.analysis {
                JournalConversationComposer(entry: root, rootID: root.id, analysis: analysis, knownKanji: knownKanji) { await conversation.load() }.id(analysis.id)
            }
        }.task { await conversation.load() }
    }
}

private struct JournalConversationReply: View {
    let node: JournalConversationNode
    let root: JournalEntryModel
    let knownKanji: Set<Character>
    let last: Bool
    let refresh: () async -> Bool
    @State private var model: JournalEntryModel

    init(node: JournalConversationNode, root: JournalEntryModel, knownKanji: Set<Character>, last: Bool, refresh: @escaping () async -> Bool) {
        self.node = node; self.root = root; self.knownKanji = knownKanji; self.last = last; self.refresh = refresh
        _model = State(initialValue: JournalEntryModel(id: node.id, store: root.store, initial: node))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 24) {
                if let question = node.question, let parentID = node.parentEntryId {
                    JournalTeacherView(question: question, parentID: parentID, service: root.store.service, knownKanji: knownKanji)
                }
                Divider()
                replyContent
            }.padding(12)
                .background(Color(red: 0.98, green: 0.99, blue: 1), in: .rect(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(Color.blue.opacity(0.12)) }
                .accessibilityElement(children: .contain).accessibilityLabel("Conversation reply")
            if last, model.analysis?.status == .ready, !model.isEditing, let analysis = model.analysis {
                JournalConversationComposer(entry: model, rootID: root.id, analysis: analysis, knownKanji: knownKanji, refresh: refresh).id(analysis.id)
            }
        }.onDisappear { model.clarification.cancel() }.task(id: node.revision) { await model.load(snapshot: node) }
            .task(id: "\(model.analysis?.id ?? ""):\(model.analysis?.status.rawValue ?? "")") { await model.poll() }
    }

    @ViewBuilder private var replyContent: some View {
        if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
        if model.clarification.active {
            JournalClarificationView(model: model.clarification, service: model.store.service)
        } else if model.analysis?.status == .ready, !model.isEditing {
            JournalFeedbackView(model: model, knownKanji: knownKanji, followUp: false, nested: true)
        } else {
            if model.analysis == nil { Text("Saved. Submit to get feedback.").font(.footnote).foregroundStyle(.secondary) }
            JournalEntryForm(model: model)
            if let analysis = model.analysis, analysis.status.isPending { JournalProgressView(status: analysis.status, serverTime: analysis.updatedAt) }
            if model.analysis?.status == .failed { Text(model.analysis?.error ?? "Try Submit again.").foregroundStyle(.red) }
        }
    }
}
