import Foundation
import XCTest
@testable import ConvoLab

final class ReadingPageResourceLoaderTests: XCTestCase {
    @MainActor
    func testSupersededPageCannotApplyLateBytesOrReportLateErrors() async {
        let outcomes: [Result<Data, any Error>] = [
            .success(Data("old page".utf8)),
            .failure(URLError(.cancelled)),
            .failure(URLError(.timedOut))
        ]
        for outcome in outcomes {
            let loader = ReadingPageResourceLoader()
            let oldPage = DeferredReadingResource()
            var applied: [Data] = []
            var failures: [String] = []
            let oldRequest = loader.load(fetch: oldPage.fetch, apply: { applied.append($0) },
                                         report: { failures.append($0.localizedDescription) })
            await oldPage.waitUntilStarted()
            // Returning to a previous page still creates a new request identity.
            let current = Data("current page".utf8)
            await loader.load(fetch: { current }, apply: { applied.append($0) },
                              report: { failures.append($0.localizedDescription) }).value
            oldPage.complete(outcome)
            await oldRequest.value

            XCTAssertEqual(applied, [current])
            XCTAssertTrue(failures.isEmpty)
        }
    }

    @MainActor
    func testLeavingReaderCancelsResourceWithoutPublishingFailure() async {
        let loader = ReadingPageResourceLoader()
        let resource = DeferredReadingResource()
        let request = loader.load(fetch: resource.fetch, apply: { _ in XCTFail("Reader has left") },
                                  report: { _ in XCTFail("Expected cancellation must stay silent") })
        await resource.waitUntilStarted()

        loader.cancel()
        resource.complete(.failure(URLError(.cancelled)))
        await request.value
    }

    @MainActor
    func testCurrentFailuresRemainVisibleIncludingUnexpectedTransportCancellation() async {
        let errors: [any Error] = [URLError(.timedOut), URLError(.cancelled), APIClientError.invalidResponse]
        for error in errors {
            let loader = ReadingPageResourceLoader()
            var failures: [String] = []
            await loader.load(fetch: { throw error }, apply: { _ in XCTFail("No valid bytes") },
                              report: { failures.append($0.localizedDescription) }).value

            XCTAssertEqual(failures, [error.localizedDescription])
        }
    }

    @MainActor
    func testReplacedPageIgnoresFailureFromAnAlreadyStartedImageApplication() async {
        let loader = ReadingPageResourceLoader()
        let application = DeferredReadingResource()
        let oldRequest = loader.load(fetch: { Data() }, apply: { _ in _ = try await application.fetch() },
                                     report: { _ in XCTFail("Old application cannot report for a new page") })
        await application.waitUntilStarted()
        var currentApplied = false
        await loader.load(fetch: { Data() }, apply: { _ in currentApplied = true },
                          report: { _ in XCTFail("Current image succeeded") }).value

        application.complete(.failure(URLError(.timedOut)))
        await oldRequest.value

        XCTAssertTrue(currentApplied)
    }
}

@MainActor
private final class DeferredReadingResource {
    private var continuation: CheckedContinuation<Data, any Error>?
    private var started: CheckedContinuation<Void, Never>?

    nonisolated deinit {}

    func fetch() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func complete(_ result: Result<Data, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
