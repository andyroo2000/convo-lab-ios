import Foundation

enum StudyCardActionExecution {
    struct Input {
        let action: StudyCardActionName
        let card: StudyCard
        let mode: StudyCardSetDueMode?
        let dueAt: Date?
        let timeZone: TimeZone
    }
}

enum StudyCardActionPresentation {
    struct Input {
        let updatedCard: StudyCard
        let sessionCards: [StudyCard]
        let libraryCards: [StudyCard]
        let wasInActiveSession: Bool
        let lessonSessionIsPresented: Bool
        let now: Date
    }

    struct Result {
        let sessionCards: [StudyCard]
        let libraryCards: [StudyCard]
        let completedCardID: String?
        let staysInActiveSession: Bool
    }

    static func project(_ input: Input) -> Result {
        let identifiers = StudyCardIdentity.identifiers(for: input.updatedCard)
        let staysInActiveSession = input.wasInActiveSession
            && !input.lessonSessionIsPresented
            && input.updatedCard.isEligibleForOfflineStudy(at: input.now)
        return Result(
            sessionCards: projectedSessionCards(
                input,
                identifiers: identifiers,
                staysInActiveSession: staysInActiveSession
            ),
            libraryCards: projectedLibraryCards(input, identifiers: identifiers),
            completedCardID: completedCardID(
                input,
                staysInActiveSession: staysInActiveSession
            ),
            staysInActiveSession: staysInActiveSession
        )
    }

    private static func projectedSessionCards(
        _ input: Input,
        identifiers: Set<String>,
        staysInActiveSession: Bool
    ) -> [StudyCard] {
        guard staysInActiveSession else {
            return input.sessionCards.filter {
                !StudyCardIdentity.matches($0, any: identifiers)
            }
        }
        return input.sessionCards.map {
            StudyCardIdentity.matches($0, any: identifiers)
                ? input.updatedCard
                : $0
        }
    }

    private static func projectedLibraryCards(
        _ input: Input,
        identifiers: Set<String>
    ) -> [StudyCard] {
        var cards = input.libraryCards
        guard let index = cards.firstIndex(where: {
            StudyCardIdentity.matches($0, any: identifiers)
        }) else {
            cards.append(input.updatedCard)
            return cards
        }
        cards[index] = input.updatedCard
        return cards
    }

    private static func completedCardID(
        _ input: Input,
        staysInActiveSession: Bool
    ) -> String? {
        guard !staysInActiveSession, input.wasInActiveSession else {
            return nil
        }
        return input.updatedCard.id
    }
}
