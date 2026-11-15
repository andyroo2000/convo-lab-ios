import UIKit
import XCTest
@testable import ConvoLab

@MainActor
final class JournalAvatarCacheTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!
    private let url = URL(string: "https://avatars.test/haru.png?v=1")!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        MockURLProtocol.deferredHandler = nil
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testMemoryAndDiskAvoidRepeatedDownloads() async {
        serveImage()
        let cache = makeCache()
        let first = await cache.image(for: url)
        XCTAssertNotNil(first)
        MockURLProtocol.handler = { _ in XCTFail("Cached avatar should not download"); throw URLError(.unknown) }
        let second = await cache.image(for: url)
        XCTAssertTrue(first === second)
        let relaunched = await makeCache().image(for: url)
        XCTAssertNotNil(relaunched)
    }

    func testPreloadAndVisibleRequestsShareOneDownload() async {
        let started = expectation(description: "One download")
        started.assertForOverFulfill = true
        let data = png()
        MockURLProtocol.deferredHandler = { request, finish in
            started.fulfill()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                finish(.success((HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)))
            }
        }
        let cache = makeCache()
        cache.preload([url.absoluteString, url.absoluteString])
        let requestURL = url
        async let first = cache.image(for: requestURL)
        async let second = cache.image(for: requestURL)
        let images = await (first, second)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertNotNil(images.0)
        XCTAssertTrue(images.0 === images.1)
    }

    func testBackendURLVersionDownloadsNewArtwork() async {
        serveImage()
        let cache = makeCache()
        _ = await cache.image(for: url)
        let changed = URL(string: "https://avatars.test/haru.png?v=2")!
        let downloaded = expectation(description: "New backend URL")
        let data = png()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url, changed)
            downloaded.fulfill()
            return (HTTPURLResponse(url: changed, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let result = await cache.image(for: changed)
        XCTAssertNotNil(result)
        await fulfillment(of: [downloaded], timeout: 2)
    }

    func testExpiredDiskImageIsAvailableBeforeRefreshAndSurvivesFailure() async {
        serveImage()
        _ = await makeCache().image(for: url)
        let cache = makeCache(lifetime: -1)
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let stored = await cache.storedImage(for: url)
        XCTAssertNotNil(stored)
        let fallback = await cache.image(for: url)
        XCTAssertNotNil(fallback)
        serveImage()
        let refreshed = await cache.image(for: url)
        XCTAssertNotNil(refreshed)
        XCTAssertFalse(stored === refreshed)
    }

    func testInvalidResponsesAreNotCachedAndCanRetry() async {
        let cache = makeCache()
        for status in [200, 404] {
            MockURLProtocol.handler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data("not an image".utf8))
            }
            let result = await cache.image(for: url)
            XCTAssertNil(result)
            XCTAssertNil(cache.cachedImage(for: url))
        }
        serveImage()
        let result = await cache.image(for: url)
        XCTAssertNotNil(result)
    }

    func testResolutionPreservesBackendURLsAndRejectsNonHTTPAssets() async {
        let cache = makeCache()
        XCTAssertEqual(cache.resolve("/avatar.png?v=2")?.absoluteString, "https://avatars.test/avatar.png?v=2")
        XCTAssertEqual(cache.resolve(url.absoluteString), url)
        XCTAssertNil(cache.resolve(nil))
        XCTAssertNil(cache.resolve(""))
        XCTAssertNil(cache.resolve("file:///private/avatar.png"))
    }

    private func makeCache(lifetime: TimeInterval = 3_600) -> JournalAvatarCache {
        JournalAvatarCache(session: session, directory: directory, baseURL: URL(string: "https://avatars.test")!, lifetime: lifetime)
    }

    private func serveImage() {
        let data = png()
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
    }

    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData()!
    }
}
