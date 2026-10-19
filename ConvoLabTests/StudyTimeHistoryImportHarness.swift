import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class StudyTimeHistoryImportHarness {
    let directory: URL
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init(inMemory: Bool = false) throws {
        // Keep these disposable stores in the temporary directory. Unlinking
        // SQLite files while a context still owns them can corrupt teardown.
        directory = FileManager.default.temporaryDirectory.appending(path: "HistoryImport-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema([LocalStudyActivitySession.self])
        let configuration = inMemory
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            : ModelConfiguration(schema: schema, url: directory.appending(path: "history.store"),
                                 cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context.autosaveEnabled = false
    }

    nonisolated deinit {}

    func importer(
        saver: StudyTimeHistoryImportSaver, batchSize: Int = 2,
        yieldControl: @escaping @MainActor () async -> Void = { await Task.yield() }
    ) -> StudyTimeHistoryImporter {
        StudyTimeHistoryImporter(context: context, saver: saver, batchSize: batchSize, yieldControl: yieldControl)
    }

    func seed(_ session: StudyActivitySession, userID: Int = 42, pending: Bool = false, tombstone: Bool = false) {
        let record = LocalStudyActivitySession(session: session, userID: userID)
        record.syncPending = pending
        record.isTombstone = tombstone
        context.insert(record)
    }

    func seedActive(_ identifier: String, at date: Date, userID: Int = 42) {
        let value = StudyTimeActiveSession(clientSessionID: identifier, category: .immerse, activity: .reading,
                                           source: .manual, name: "Reading now", startedAt: date, cardsCreated: 0)
        context.insert(LocalStudyActivitySession(active: value, userID: userID))
    }

    func records(userID: Int = 42) throws -> [LocalStudyActivitySession] {
        try context.fetch(FetchDescriptor<LocalStudyActivitySession>(predicate: #Predicate { $0.userID == userID }))
    }

    func changeName(_ identifier: String, to name: String) throws {
        try XCTUnwrap(records().first { $0.clientSessionID == identifier }).name = name
    }

    func savePendingEdit(_ identifier: String, name: String) throws {
        let record = try XCTUnwrap(records().first { $0.clientSessionID == identifier })
        record.name = name
        record.syncPending = true
        try context.save()
    }

    func deleteRecords(userID: Int = 42) throws {
        try context.delete(model: LocalStudyActivitySession.self, where: #Predicate { $0.userID == userID })
        try context.save()
    }

    func expectSuccessfulMutation(_ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        do {
            try action()
        } catch {
            XCTFail("The foreground mutation failed: \(error)", file: file, line: line)
        }
    }

    func persistedIDs(userID: Int = 42) throws -> [String] {
        let reader = ModelContext(container)
        return try reader.fetch(FetchDescriptor<LocalStudyActivitySession>(predicate: #Predicate { $0.userID == userID }))
            .map(\.clientSessionID).sorted()
    }

    func persistedName(_ identifier: String, userID: Int = 42) throws -> String? {
        let reader = ModelContext(container)
        return try reader.fetch(FetchDescriptor<LocalStudyActivitySession>(predicate: #Predicate {
            $0.userID == userID && $0.clientSessionID == identifier
        })).first?.name
    }

    static func session(_ index: Int, name: String? = nil, start: Date? = nil,
                        clientSessionID: String? = nil) -> StudyActivitySession {
        let startedAt = start ?? Date(timeIntervalSince1970: 1_792_425_600.123_456)
        return .init(id: "server-\(index)", clientSessionId: clientSessionID ?? String(format: "row-%03d", index),
                     category: .wanikani, activity: .wanikaniReview, source: .manual, origin: .ios,
                     name: name ?? "日本語 \(index)", startedAt: startedAt, endedAt: startedAt.addingTimeInterval(60),
                     durationMs: 60_000, audioPlaybackMs: nil, cardsCreated: nil)
    }
}

@MainActor
final class StudyTimeHistoryImportSaver: StudyTimeContextSaving {
    enum Failure: Error { case injected }
    private weak var context: ModelContext?
    private let failures: Set<Int>
    private(set) var calls = 0

    init(context: ModelContext, failures: Set<Int> = []) {
        self.context = context
        self.failures = failures
    }

    nonisolated deinit {}

    func save() throws {
        calls += 1
        if failures.contains(calls) { throw Failure.injected }
        try XCTUnwrap(context).save()
    }
}

@MainActor
final class StudyTimeHistoryImportGate {
    let reached = XCTestExpectation(description: "Import reached a committed yield boundary")
    private var continuation: CheckedContinuation<Void, Never>?
    private var didPause = false
    nonisolated deinit {}

    func pause() async {
        guard !didPause else { return }
        didPause = true
        await withCheckedContinuation {
            continuation = $0
            reached.fulfill()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
