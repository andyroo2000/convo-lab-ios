import Foundation

struct JournalSelection {
    let id: String
    var draft: JournalDraft? = nil

    static func blank() -> JournalSelection {
        let draft = JournalDraft.new()
        return JournalSelection(id: draft.id, draft: draft)
    }

    static func today(entries: [JournalEntry], drafts: [JournalDraft], date: String) -> String? {
        let online = entries.filter { $0.rootEntryId == nil && $0.entryDate == date && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.id)
        let local = drafts.filter { $0.rootEntryId == nil && $0.entryDate == date && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.id)
        return (online + local).max()
    }
}
