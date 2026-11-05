import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    private static let togglePileID = "01jzq4nny5xbnzw14q1g68b2yt"
    private static let toggleChapterID = "01jzq4nny5xbnzw14q1g68b2yv"

    @MainActor
    func testPileSaveReturnsBeforeCountsAndOverviewRefresh() async throws {
        let refresh = LockedDeferredResponse()
        let overview = LockedDeferredResponse()
        let store = try seededPileStore { request, completion in
            switch request.url?.path {
            case "/api/study/piles": refresh.hold(completion)
            case "/api/study/overview": overview.hold(completion)
            default: completion(.success(Self.response(data: Data("{}".utf8))))
            }
        }
        try await saveTestChapter(store)
        XCTAssertEqual(store.piles.catalog?.piles.first?.chapters.first?.isActive, false)
        XCTAssertFalse(store.piles.hasPendingSaves)
        await waitUntil { refresh.hasPendingResponse }
        XCTAssertTrue(store.piles.isRefreshing)
        refresh.succeed(with: Self.response(data: try savedPileData(store)))
        await waitUntil { overview.hasPendingResponse }
        XCTAssertFalse(store.piles.hasPendingSaves)
        overview.succeed(with: Self.response(statusCode: 503, data: Data("{}".utf8)))
        await store.piles.refreshTask?.value
    }

    @MainActor
    func testFailedPileSavePreservesPersistedSwitch() async throws {
        let store = try seededPileStore { request, completion in
            let status = request.httpMethod == "PUT" ? 503 : 200
            completion(.success(Self.response(statusCode: status, data: Self.pileCatalogData)))
        }
        do {
            try await saveTestChapter(store)
            XCTFail("Expected the failed write to be reported")
        } catch {}
        XCTAssertEqual(store.piles.catalog?.piles.first?.chapters.first?.isActive, true)
        XCTAssertFalse(store.piles.hasPendingSaves)
        await store.piles.refreshTask?.value
    }

    @MainActor
    func testPileRefreshFailureDoesNotUndoSuccessfulSave() async throws {
        let store = try seededPileStore { request, completion in
            let status = request.httpMethod == "PUT" ? 200 : 503
            completion(.success(Self.response(statusCode: status, data: Data("{}".utf8))))
        }
        try await saveTestChapter(store)
        await store.piles.refreshTask?.value
        XCTAssertEqual(store.piles.catalog?.piles.first?.chapters.first?.isActive, false)
        XCTAssertNotNil(store.piles.errorMessage)
        XCTAssertFalse(store.piles.isRefreshing)
    }

    @MainActor
    func testStalePileRefreshCannotUndoSavedChapter() async throws {
        let stale = LockedDeferredResponse()
        let store = try seededPileStore { request, completion in
            if request.url?.path == "/api/study/piles" { stale.hold(completion) }
            else { completion(.success(Self.response(data: Data("{}".utf8)))) }
        }
        let refreshTask = Task { await store.refreshPiles() }
        await waitUntil { stale.hasPendingResponse }
        let blocker = store.piles.beginSave()
        try await saveTestChapter(store)
        stale.succeed(with: Self.response(data: Self.pileCatalogData))
        await refreshTask.value
        XCTAssertEqual(store.piles.catalog?.piles.first?.chapters.first?.isActive, false)
        XCTAssertTrue(store.piles.finishSave(blocker))
        store.deactivate()
    }

    @MainActor
    func testOverlappingPileSavesPreserveSuccessAndRefreshOnlyAfterLastWrite() async throws {
        let bookWrite = LockedDeferredResponse()
        let chapterWrite = LockedDeferredResponse()
        let refresh = LockedDeferredResponse()
        let store = try seededPileStore { request, completion in
            if request.httpMethod == "PUT" {
                let gate = request.url?.path.contains("/chapters/") == true ? chapterWrite : bookWrite
                gate.hold(completion)
            } else if request.url?.path == "/api/study/piles" { refresh.hold(completion) }
            else { completion(.success(Self.response(statusCode: 503, data: Data("{}".utf8)))) }
        }
        let bookTask = Task { try await store.savePile(id: Self.togglePileID, update: .init(isActive: false)) }
        let chapterTask = Task { try await saveTestChapter(store) }
        await waitUntil { bookWrite.hasPendingResponse && chapterWrite.hasPendingResponse }
        chapterWrite.succeed(with: Self.response(data: Data("{}".utf8)))
        try await chapterTask.value
        XCTAssertTrue(store.piles.hasPendingSaves)
        XCTAssertNil(store.piles.refreshTask)
        bookWrite.succeed(with: Self.response(statusCode: 503, data: Data("{}".utf8)))
        do { try await bookTask.value; XCTFail("Expected book failure") } catch {}
        XCTAssertEqual(store.piles.catalog?.piles.first?.isActive, true)
        XCTAssertEqual(store.piles.catalog?.piles.first?.chapters.first?.isActive, false)
        await waitUntil { refresh.hasPendingResponse }
        refresh.succeed(with: Self.response(data: try savedPileData(store)))
        await store.piles.refreshTask?.value
    }

    @MainActor
    func testOldAccountPileWriteCannotPublishOrStartNewAccountRefreshes() async throws {
        let write = LockedDeferredResponse()
        let store = try seededPileStore { request, completion in
            XCTAssertEqual(request.httpMethod, "PUT")
            write.hold(completion)
        }
        let task = Task { try await saveTestChapter(store) }
        await waitUntil { write.hasPendingResponse }
        store.activate(userID: 2)
        write.succeed(with: Self.response(data: Data("{}".utf8)))
        try await task.value
        XCTAssertNil(store.piles.catalog)
        XCTAssertFalse(store.piles.hasPendingSaves)
        XCTAssertNil(store.piles.refreshTask)
    }

    @MainActor
    func testPileAttributePatchPreservesChapterChoicesAndCounts() async throws {
        var catalog = try StorageCodec.decoder.decode(StudyPileCatalog.self, from: Self.pileCatalogData)
        let original = try XCTUnwrap(catalog.piles.first)
        catalog.apply(.init(title: "New title", position: 9, isActive: false),
                      id: Self.togglePileID, pileID: nil)
        let updated = try XCTUnwrap(catalog.piles.first)
        XCTAssertEqual(updated.title, "New title")
        XCTAssertEqual(updated.position, 9)
        XCTAssertFalse(updated.isActive)
        XCTAssertEqual(updated.chapters, original.chapters)
        XCTAssertEqual(updated.newCount, original.newCount)
        XCTAssertEqual(updated.readyCount, original.readyCount)
    }

    @MainActor
    private func seededPileStore(handler: @escaping MockURLProtocol.DeferredHandler) throws -> StudyStore {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeDeferredClient(handler: handler)
        client.setAccessToken("test-token")
        let store = makePileStore(container, client)
        store.piles.catalog = try StorageCodec.decoder.decode(StudyPileCatalog.self, from: Self.pileCatalogData)
        return store
    }

    @MainActor
    private func saveTestChapter(_ store: StudyStore) async throws {
        try await store.savePile(id: Self.toggleChapterID.uppercased(),
                                 update: .init(isActive: false), pileID: Self.togglePileID.uppercased())
    }

    @MainActor
    private func savedPileData(_ store: StudyStore) throws -> Data {
        try StorageCodec.encoder.encode(XCTUnwrap(store.piles.catalog))
    }
}
