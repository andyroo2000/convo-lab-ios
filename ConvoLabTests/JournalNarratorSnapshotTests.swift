import XCTest
@testable import ConvoLab

@MainActor
final class JournalNarratorSnapshotTests: XCTestCase {
    func testCachedPortraitMetadataAppearsBeforeValidationWithoutEnablingPlayback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("narrator.json")
        let catalog = try JSONDecoder().decode([JournalVoice].self, from: Data(#"[{"id":"yua","name":"Yua"}]"#.utf8))
        await JournalNarratorSnapshot.shared.write(.init(analysisID: "a", revision: 2, voices: catalog, selected: "yua"), to: url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(baseURL: URL(string: "https://journal.test")!, session: URLSession(configuration: configuration))
        api.setAccessToken("test")
        let requested = expectation(description: "Validation requested")
        requested.expectedFulfillmentCount = 2
        MockURLProtocol.deferredHandler = { _, complete in
            requested.fulfill()
            Task { try? await Task.sleep(for: .milliseconds(100)); complete(.failure(URLError(.notConnectedToInternet))) }
        }
        defer { MockURLProtocol.deferredHandler = nil }
        let selection = JournalVoiceSelection()
        let analysis = JournalAnalysis(id: "a", sourceVersion: 1, status: .ready, result: nil, error: nil, updatedAt: "now", replyRevision: 2)
        let load = Task { await selection.load(entryID: "01arz3ndektsv4rrffq69g5fav", analysis: analysis, service: JournalService(api: api), snapshotURL: url) }
        await fulfillment(of: [requested], timeout: 3)
        XCTAssertEqual(selection.selected, "yua")
        XCTAssertEqual(selection.voices.first?.name, "Yua")
        XCTAssertFalse(selection.isReady)
        await load.value
        XCTAssertFalse(selection.isReady)
        XCTAssertNotNil(selection.errorMessage)
    }

    func testRemovedAccountDirectoryIsNotRecreatedByLateWrites() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("narrator.json")
        await JournalNarratorSnapshot.shared.write(.init(analysisID: "a", revision: 1, voices: [], selected: ""), to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        let value = await JournalNarratorSnapshot.shared.read(url)
        XCTAssertNil(value)
    }
}
