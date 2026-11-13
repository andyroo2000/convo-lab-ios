import Foundation

struct JournalDraft: Codable, Identifiable, Equatable {
    let id: String
    var title: String?
    var body: String
    var entryDate: String
    var expectedVersion: Int
    var editID: String
    var rootEntryId: String? = nil

    static func new(date: Date = .now) -> JournalDraft {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return JournalDraft(id: ClientIdentifier.ulid().lowercased(), title: nil, body: "",
                            entryDate: formatter.string(from: date), expectedVersion: 0,
                            editID: UUID().uuidString)
    }

    init(entry: JournalEntry) {
        id = entry.id
        rootEntryId = entry.rootEntryId
        title = entry.title
        body = entry.body
        entryDate = entry.entryDate
        expectedVersion = entry.version
        editID = UUID().uuidString
    }

    init(id: String, title: String?, body: String, entryDate: String, expectedVersion: Int, editID: String) {
        self.id = id
        self.title = title
        self.body = body
        self.entryDate = entryDate
        self.expectedVersion = expectedVersion
        self.editID = editID
    }
}

nonisolated struct JournalSavePayload: Encodable, Sendable {
    let title: String?
    let body: String
    let entryDate: String
    let expectedVersion: Int

    private enum CodingKeys: String, CodingKey { case title, body, entryDate, expectedVersion }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        // The API distinguishes a cleared title from an omitted field.
        if let title { try values.encode(title, forKey: .title) }
        else { try values.encodeNil(forKey: .title) }
        try values.encode(body, forKey: .body)
        try values.encode(entryDate, forKey: .entryDate)
        try values.encode(expectedVersion, forKey: .expectedVersion)
    }
}
