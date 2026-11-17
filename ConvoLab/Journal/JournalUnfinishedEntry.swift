import Foundation

@MainActor
enum JournalUnfinishedEntry {
    static func find(service: JournalService) async throws -> String? {
        let page: JournalArchivePage = try await service.request("/api/journal/entries", query: [
            URLQueryItem(name: "unfinished", value: "1"),
            URLQueryItem(name: "limit", value: "1")
        ])
        return page.data.first?.id
    }
}
