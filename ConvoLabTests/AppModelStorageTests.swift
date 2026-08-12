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

        let card = reviewCard()
        do {
            try await model.study.updateCard(card, draft: StudyCardDraft(card: card))
            XCTFail("Expected temporary storage to reject the card update")
        } catch {
            assertStorageError(error, domain: .study)
        }
        do {
            try await model.study.deleteCard(card)
            XCTFail("Expected temporary storage to reject the card delete")
        } catch {
            assertStorageError(error, domain: .study)
        }
        do {
            _ = try await model.study.regenerateImage(
                for: card,
                prompt: "new image",
                placement: .prompt
            )
            XCTFail("Expected temporary storage to reject the media update")
        } catch {
            assertStorageError(error, domain: .study)
        }
        do {
            try await model.study.retryPendingDraftCommits()
            XCTFail("Expected temporary storage to reject the draft retry")
        } catch {
            assertStorageError(error, domain: .study)
        }
        XCTAssertEqual(
            try model.container.mainContext.fetchCount(FetchDescriptor<PendingMutation>()),
            0
        )

        let eventID = await model.study.recordReview(
            card: card,
            rating: .good,
            duration: .seconds(2)
        )

        XCTAssertNil(eventID)
        XCTAssertEqual(
            model.study.syncStatus,
            .failed(StorageWriteUnavailableError(domain: .study).localizedDescription)
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

        model.studyTime.start(activity: .reading, source: .manual)
        XCTAssertNil(model.studyTime.syncErrorMessage)

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

        let session = studyTimeSession()
        do {
            _ = try await model.studyTime.update(
                session: session,
                activity: .reading,
                name: "Edited",
                startedAt: .now,
                duration: 300
            )
            XCTFail("Expected temporary storage to reject the study-time update")
        } catch {
            assertStorageError(error, domain: .studyTime)
        }
        do {
            try await model.studyTime.delete(session: session)
            XCTFail("Expected temporary storage to reject the study-time delete")
        } catch {
            assertStorageError(error, domain: .studyTime)
        }
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

    private func assertStorageError(_ error: any Error, domain: StorageDomain) {
        if let error = error as? StorageWriteUnavailableError {
            XCTAssertEqual(error.domain, domain)
        } else {
            XCTFail("Expected StorageWriteUnavailableError, got \(error)")
        }
    }

    private func reviewCard() -> StudyCard {
        StudyCard(
            id: "01J0000000000000000000000RV",
            syncId: nil,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string("復習")]),
            answer: .object(["meaning": .string("review")]),
            state: .init(
                dueAt: .now,
                introducedAt: nil,
                failedAt: nil,
                queueState: "review",
                scheduler: .object([:]),
                source: .object([:])
            ),
            answerAudioSource: "missing",
            masteryLevel: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }

    private func studyTimeSession() -> StudyActivitySession {
        StudyActivitySession(
            id: "server-study-time-session",
            clientSessionId: "study-time-session",
            category: .immerse,
            activity: .reading,
            source: .manual,
            name: "Reading",
            startedAt: .now.addingTimeInterval(-600),
            endedAt: .now,
            durationMs: 600_000,
            audioPlaybackMs: nil,
            cardsCreated: nil
        )
    }
}
