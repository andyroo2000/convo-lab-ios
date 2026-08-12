import Foundation

enum StudySessionLoadKind {
    case reviews
    case lessons

    fileprivate var path: String {
        switch self {
        case .reviews: "/api/study/session/start"
        case .lessons: "/api/study/lessons/start"
        }
    }
}

struct StudySessionLoad {
    let response: StudySessionResponse
    let userID: Int
    fileprivate let generation: Int
    fileprivate let revision: Int
}

@MainActor
final class StudySessionLoadingService {
    private struct Operation {
        let userID: Int
        let generation: Int
        let revision: Int
    }

    private let api: APIClient
    private var activeUserID: Int?
    private var generation = 0
    private var revision = 0

    init(api: APIClient) {
        self.api = api
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        generation += 1
        revision += 1
        activeUserID = userID
    }

    func deactivate() {
        generation += 1
        revision += 1
        activeUserID = nil
    }

    func invalidate() {
        revision += 1
    }

    func load(_ kind: StudySessionLoadKind) async throws -> StudySessionLoad? {
        guard let activeUserID else { return nil }
        revision += 1
        let operation = Operation(
            userID: activeUserID,
            generation: generation,
            revision: revision
        )
        let response: StudySessionResponse = try await api.request(
            kind.path,
            method: "POST",
            body: ["time_zone": TimeZone.current.identifier]
        )
        guard
            self.activeUserID == operation.userID,
            generation == operation.generation,
            revision == operation.revision
        else { return nil }
        return StudySessionLoad(
            response: response,
            userID: operation.userID,
            generation: operation.generation,
            revision: operation.revision
        )
    }

    func isCurrent(_ load: StudySessionLoad) -> Bool {
        activeUserID == load.userID
            && generation == load.generation
            && revision == load.revision
    }
}
