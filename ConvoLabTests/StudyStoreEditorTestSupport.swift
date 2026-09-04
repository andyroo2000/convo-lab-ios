import SwiftData
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func insertEditorCard(_ card: StudyCard, into container: ModelContainer) throws {
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
    }

    @MainActor
    func makeEditorStore(container: ModelContainer, client: APIClient) -> StudyStore {
        StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )
    }
}
