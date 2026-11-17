import Foundation

@MainActor
enum JournalUnfinishedEntry {
    static func find(entries: [JournalEntry], cursor: String?, service: JournalService) async throws -> String? {
        for entry in entries where !entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let response = try await service.analysis(entry.id)
            if response.data == nil || response.data?.status == .failed { return entry.id }
        }
        guard let cursor else { return nil }
        let page = try await service.archive(cursor: cursor)
        let next = page.nextCursor == cursor ? nil : page.nextCursor
        return try await find(entries: page.data, cursor: next, service: service)
    }
}
