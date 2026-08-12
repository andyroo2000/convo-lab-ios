import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class AppModelStorageTests: XCTestCase {
    private enum TestFailure: Error {
        case unavailable
    }

    func testLaunchReportsMainStoreFallbackAndRejectsCardWrites() async throws {
        let model = AppModel(
            configuration: testConfiguration(),
            makeContainer: { inMemory in
                guard inMemory else { throw TestFailure.unavailable }
                return try Persistence.makeContainer(inMemory: true)
            },
            makeStudyTimeContainer: { _ in
                try StudyTimePersistence.makeContainer(inMemory: true)
            }
        )

        XCTAssertEqual(model.storageStatus.study, .temporary)
        XCTAssertEqual(model.storageStatus.studyTime, .persistent)
        XCTAssertEqual(
            model.storageStatus.warningMessage,
            "Study data is using temporary storage. Card and review changes are disabled until you relaunch the app."
        )

        model.study.activate(userID: 42)
        do {
            try await model.study.createCard(
                expression: "猫",
                reading: "ねこ",
                meaning: "cat"
            )
            XCTFail("Expected temporary storage to reject the card write")
        } catch let error as StorageWriteUnavailableError {
            XCTAssertEqual(error.domain, .study)
        }
        XCTAssertEqual(
            try model.container.mainContext.fetchCount(FetchDescriptor<LocalCardRecord>()),
            0
        )
        XCTAssertEqual(
            try model.container.mainContext.fetchCount(FetchDescriptor<PendingMutation>()),
            0
        )
    }

    func testLaunchReportsStudyTimeFallbackAndRejectsTimerWrites() async throws {
        let model = AppModel(
            configuration: testConfiguration(),
            makeContainer: { _ in
                try Persistence.makeContainer(inMemory: true)
            },
            makeStudyTimeContainer: { inMemory in
                guard inMemory else { throw TestFailure.unavailable }
                return try StudyTimePersistence.makeContainer(inMemory: true)
            }
        )

        XCTAssertEqual(model.storageStatus.study, .persistent)
        XCTAssertEqual(model.storageStatus.studyTime, .temporary)
        XCTAssertEqual(
            model.storageStatus.warningMessage,
            "Study time is using temporary storage. Recording and editing study time are disabled until you relaunch the app."
        )

        model.studyTime.activate(userID: 42)
        model.studyTime.start(activity: .reading, source: .manual)

        XCTAssertNil(model.studyTime.active)
        XCTAssertEqual(
            model.studyTime.syncErrorMessage,
            StorageWriteUnavailableError(domain: .studyTime).localizedDescription
        )
        XCTAssertEqual(
            try model.studyTimeContainer.mainContext.fetchCount(
                FetchDescriptor<LocalStudyActivitySession>()
            ),
            0
        )

        do {
            _ = try await model.studyTime.recordCompleted(
                activity: .reading,
                source: .manual,
                name: "Reading",
                startedAt: .now,
                duration: 600
            )
            XCTFail("Expected temporary storage to reject the completed entry")
        } catch let error as StorageWriteUnavailableError {
            XCTAssertEqual(error.domain, .studyTime)
        }
        XCTAssertEqual(
            try model.studyTimeContainer.mainContext.fetchCount(
                FetchDescriptor<LocalStudyActivitySession>()
            ),
            0
        )
    }

    func testLaunchReportsBothFallbacks() async throws {
        let model = AppModel(
            configuration: testConfiguration(),
            makeContainer: fallbackOnly { try Persistence.makeContainer(inMemory: $0) },
            makeStudyTimeContainer: fallbackOnly(StudyTimePersistence.makeContainer)
        )

        XCTAssertEqual(model.storageStatus.study, .temporary)
        XCTAssertEqual(model.storageStatus.studyTime, .temporary)
        XCTAssertEqual(
            model.storageStatus.warningMessage,
            "ConvoLab is using temporary storage. Card, review, and study-time changes are disabled until you relaunch the app."
        )
    }

    func testLaunchReportsHealthyStoresWithoutWarning() async throws {
        let model = AppModel(
            configuration: testConfiguration(),
            makeContainer: { _ in try Persistence.makeContainer(inMemory: true) },
            makeStudyTimeContainer: { _ in
                try StudyTimePersistence.makeContainer(inMemory: true)
            }
        )

        XCTAssertEqual(
            model.storageStatus,
            StorageStatus(study: .persistent, studyTime: .persistent)
        )
        XCTAssertNil(model.storageStatus.warningMessage)
    }

    private func fallbackOnly(
        _ factory: @escaping (Bool) throws -> ModelContainer
    ) -> (Bool) throws -> ModelContainer {
        { inMemory in
            guard inMemory else { throw TestFailure.unavailable }
            return try factory(true)
        }
    }

    private func testConfiguration() -> AppConfiguration {
        AppConfiguration(apiBaseURL: URL(string: "https://example.com")!)
    }
}
