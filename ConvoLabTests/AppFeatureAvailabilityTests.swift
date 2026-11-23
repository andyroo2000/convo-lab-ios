import XCTest
@testable import ConvoLab

final class AppFeatureAvailabilityTests: XCTestCase {
    func testJournalOnlyDefaultsKeepSettingsAccessible() {
        XCTAssertEqual(AppFeatureFlags.journalOnly.modes, [.journal, .settings])
    }

    func testEachSwitchControlsItsOwnDestinations() {
        let study = AppFeatureFlags(flashcardsEnabled: true, readingsEnabled: false, studyTimeEnabled: false)
        XCTAssertEqual(study.modes, [.journal, .settings, .study, .cards])
        let readingAndTime = AppFeatureFlags(flashcardsEnabled: false, readingsEnabled: true, studyTimeEnabled: true)
        XCTAssertEqual(readingAndTime.modes, [.journal, .settings, .readings, .time])
    }

    func testEffectiveAdminFlagsAllowAllModes() throws {
        let data = Data(#"{"flashcardsEnabled":true,"readingsEnabled":true,"studyTimeEnabled":true}"#.utf8)
        let flags = try JSONDecoder().decode(AppFeatureFlags.self, from: data)
        XCTAssertEqual(flags.modes, Set(AppMode.allCases))
    }

    @MainActor
    func testSuccessfulFlagsPersistPerAccountAndSurviveOfflineRefresh() async throws {
        let suite = "FeatureAvailabilityTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = client(status: 200)
        let availability = AppFeatureAvailability(cacheKey: "account-a", defaults: defaults)
        await availability.refresh(api: api)
        let restored = AppFeatureAvailability(cacheKey: "account-a", defaults: defaults)
        XCTAssertTrue(restored.flags.flashcardsEnabled)
        XCTAssertEqual(AppFeatureAvailability(cacheKey: "account-b", defaults: defaults).flags, .journalOnly)
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await restored.refresh(api: api)
        XCTAssertTrue(restored.flags.flashcardsEnabled)
    }

    @MainActor
    func testDefinitiveRejectionClearsEnabledFlags() async {
        for status in [401, 403, 404] {
            let availability = AppFeatureAvailability(flags: .init(
                flashcardsEnabled: true, readingsEnabled: true, studyTimeEnabled: true))
            await availability.refresh(api: client(status: status))
            XCTAssertEqual(availability.flags, .journalOnly)
        }
    }

    @MainActor
    func testResponseFromPreviousCredentialIsDiscarded() async {
        let api = client(status: 200)
        api.setAccessToken("old-token")
        let started = expectation(description: "Request started")
        let release = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { request in
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"flashcardsEnabled":true,"readingsEnabled":true,"studyTimeEnabled":true}"#.utf8))
        }
        let availability = AppFeatureAvailability()
        let task = Task { await availability.refresh(api: api) }
        await fulfillment(of: [started], timeout: 5)
        api.setAccessToken("new-token")
        release.signal()
        await task.value
        XCTAssertEqual(availability.flags, .journalOnly)
    }

    @MainActor
    private func client(status: Int) -> APIClient {
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
             Data(#"{"flashcardsEnabled":true,"readingsEnabled":true,"studyTimeEnabled":true}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(baseURL: URL(string: "https://feature-flags.ui-tests.invalid")!,
                         session: URLSession(configuration: configuration))
    }
}
