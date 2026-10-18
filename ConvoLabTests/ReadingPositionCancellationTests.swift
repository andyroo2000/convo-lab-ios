import Foundation
import XCTest
@testable import ConvoLab

final class ReadingPositionCancellationTests: XCTestCase {
    @MainActor
    func testCancelledSwipeWaiterAndFinishDrainLatestPositionInBothDirections() async throws {
        for (offset, pages) in [[24, 25], [25, 24]].enumerated() {
            let fixture = try Fixture(userID: -421 - offset)
            defer { fixture.cleanup() }
            fixture.store.record(fixture.reading, pageNumber: pages[0], sentence: nil)
            let previous = try fixture.acknowledgement()
            let deferred = LockedDeferredResponse()
            let requests = LockedRequestPaths()
            MockURLProtocol.deferredHandler = { request, complete in
                requests.append(request.url!.path)
                deferred.hold(complete)
            }
            let swipe = Task { await fixture.store.synchronizePositions() }
            await deferred.waitUntilPending()

            swipe.cancel()
            fixture.store.record(fixture.reading, pageNumber: pages[1], sentence: nil)
            let latest = try fixture.acknowledgement()
            MockURLProtocol.deferredHandler = nil
            MockURLProtocol.handler = { request in
                requests.append(request.url!.path)
                return Self.response(latest)
            }
            let finish = Task { await fixture.store.synchronizePositions() }
            deferred.succeed(with: Self.response(previous))
            await swipe.value
            await finish.value

            XCTAssertEqual(requests.values.count, 2, "Finish must join and drain the latest queued page")
            XCTAssertEqual(fixture.store.position("reading")?.pageNumber, pages[1])
            XCTAssertTrue(fixture.store.snapshot.pending.isEmpty)
            XCTAssertNil(fixture.store.errorMessage)
            XCTAssertTrue(try ReadingLocalStorage(userID: fixture.userID).load().pending.isEmpty)
        }
    }

    @MainActor
    func testUnexpectedProgressTransportCancellationReportsFailureAndRetainsPendingSave() async throws {
        let fixture = try Fixture(userID: -423)
        defer { fixture.cleanup() }
        fixture.store.record(fixture.reading, pageNumber: 24, sentence: nil)
        MockURLProtocol.handler = { _ in throw URLError(.cancelled) }

        await fixture.store.synchronizePositions()

        XCTAssertEqual(fixture.store.snapshot.pending.count, 1)
        XCTAssertEqual(fixture.store.errorMessage, URLError(.cancelled).localizedDescription)
        XCTAssertEqual(try ReadingLocalStorage(userID: fixture.userID).load().pending.count, 1)
    }

    @MainActor
    func testCancelledDocumentLoadDoesNotShowTransportCancellation() async throws {
        let fixture = try Fixture(userID: -424)
        defer { fixture.cleanup() }
        let deferred = LockedDeferredResponse()
        MockURLProtocol.deferredHandler = { _, complete in deferred.hold(complete) }
        let opening = Task { await fixture.store.loadDocument("reading") }
        await deferred.waitUntilPending()

        opening.cancel()
        await opening.value

        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertNil(fixture.store.document("reading"))
    }

    @MainActor
    func testAccountChangeDuringOwnedUploadCannotAcknowledgePendingPosition() async throws {
        let fixture = try Fixture(userID: -425)
        defer { fixture.cleanup() }
        fixture.store.record(fixture.reading, pageNumber: 25, sentence: nil)
        let acknowledgement = try fixture.acknowledgement()
        let deferred = LockedDeferredResponse()
        MockURLProtocol.deferredHandler = { _, complete in deferred.hold(complete) }
        let saving = Task { await fixture.store.synchronizePositions() }
        await deferred.waitUntilPending()

        fixture.api.setAccessToken("different-account")
        deferred.succeed(with: Self.response(acknowledgement))
        await saving.value

        XCTAssertEqual(fixture.store.snapshot.pending.count, 1)
        XCTAssertTrue(fixture.store.errorMessage?.contains("session changed") == true)
    }

    nonisolated private static func response(_ data: Data) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: URL(string: "https://readings.invalid")!, statusCode: 200,
                         httpVersion: nil, headerFields: nil)!, data)
    }

    @MainActor
    private struct Fixture {
        let userID: Int
        let api: APIClient
        let store: ReadingStore
        let reading: ReadingDetail
        private let session: URLSession

        init(userID: Int) throws {
            self.userID = userID
            try ReadingLocalStorage.remove(userID: userID)
            MockURLProtocol.handler = nil
            MockURLProtocol.deferredHandler = nil
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]
            session = URLSession(configuration: configuration)
            api = APIClient(baseURL: URL(string: "https://readings.invalid")!, session: session)
            api.setAccessToken("fixture")
            store = ReadingStore(api: api, userID: userID)
            reading = ReadingDetail(
                id: "reading", title: "Story", revision: 1,
                document: ReadingDocument(title: "Story", author: "Author", pages: [
                    ReadingPage(number: 24, kind: "text", columns: []),
                    ReadingPage(number: 25, kind: "text", columns: [])
                ], sentences: []), voiceId: "voice", voiceName: "Narrator"
            )
        }

        func acknowledgement() throws -> Data {
            let position = try XCTUnwrap(store.snapshot.pending["reading"])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let object = try JSONSerialization.jsonObject(with: encoder.encode(position))
            return try JSONSerialization.data(withJSONObject: ["position": object])
        }

        func cleanup() {
            session.invalidateAndCancel()
            MockURLProtocol.handler = nil
            MockURLProtocol.deferredHandler = nil
            try? ReadingLocalStorage.remove(userID: userID)
        }
    }
}
