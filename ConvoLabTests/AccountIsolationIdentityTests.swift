import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension AccountIsolationTests {
    func testReplacingCardPayloadKeepsIndexedSyncIdentityInStep() throws {
        let originalPayload = try JSONSerialization.data(withJSONObject: [
            "syncId": "SERVER-ONE",
        ])
        let card = StudyCard(
            id: "LOCAL-CARD",
            syncId: "SERVER-ONE",
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string("prompt")]),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: nil,
                introducedAt: nil,
                failedAt: nil,
                queueState: "review",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: .now,
            updatedAt: .now
        )
        let record = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: originalPayload
        )

        XCTAssertEqual(record.syncID, "server-one")
        XCTAssertEqual(record.normalizedID, "local-card")
        let replacement = try JSONSerialization.data(withJSONObject: [
            "syncId": "SERVER-TWO",
        ])
        record.replacePayload(encoded: replacement)
        XCTAssertEqual(record.payload, replacement)
        XCTAssertEqual(record.syncID, "server-two")

        let corruptReplacement = Data("not-json".utf8)
        record.replacePayload(encoded: corruptReplacement)
        XCTAssertEqual(record.payload, corruptReplacement)
        XCTAssertEqual(record.syncID, "local-card")
    }

    func testReplacingCardIDPreservesClientAliasUntilAcknowledgementPayloadArrives() throws {
        let clientCard = StudyCard(
            id: "CLIENT-ID",
            syncId: "CLIENT-ID",
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string("prompt")]),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: nil,
                introducedAt: nil,
                failedAt: nil,
                queueState: "new",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: .now,
            updatedAt: .now
        )
        let record = LocalCardRecord(
            card: clientCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(clientCard)
        )

        record.replaceID(with: "server-id")

        XCTAssertEqual(record.id, "server-id")
        XCTAssertEqual(record.normalizedID, "server-id")
        XCTAssertEqual(record.syncID, "client-id")
        XCTAssertEqual(
            try StorageCodec.decoder.decode(StudyCard.self, from: record.payload).id,
            "CLIENT-ID"
        )

        let serverCard = clientCard.replacingIdentity(
            id: "server-id",
            syncId: "server-id"
        )
        record.replacePayload(encoded: try StorageCodec.encoder.encode(serverCard))

        XCTAssertEqual(record.syncID, "server-id")
        XCTAssertEqual(
            try StorageCodec.decoder.decode(StudyCard.self, from: record.payload).id,
            "server-id"
        )
    }
}
