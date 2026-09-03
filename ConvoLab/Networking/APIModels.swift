import Foundation

struct APIEnvelope<Value: Decodable & Sendable>: nonisolated Decodable, Sendable {
    let data: Value
}

struct CurrentUser: nonisolated Codable, Sendable {
    let id: Int
    let name: String
    let email: String
    let emailVerifiedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, email
        case emailVerifiedAt = "email_verified_at"
    }
}

struct MobileTokenResponse: nonisolated Decodable, Sendable {
    struct TokenData: nonisolated Decodable, Sendable {
        let token: String
        let tokenType: String
        let expiresAt: Date?

        enum CodingKeys: String, CodingKey {
            case token
            case tokenType = "token_type"
            case expiresAt = "expires_at"
        }
    }

    let data: TokenData
}

struct LoginRequest: Encodable {
    let email: String
    let password: String
    let deviceName: String

    enum CodingKeys: String, CodingKey {
        case email, password
        case deviceName = "device_name"
    }
}

struct RegistrationRequest: Encodable {
    let name: String
    let email: String
    let password: String
    let inviteCode: String
    let deviceName: String

    enum CodingKeys: String, CodingKey {
        // The Convo Lab compatibility API intentionally keeps inviteCode camel-cased.
        case name, email, password
        case inviteCode = "inviteCode"
        case deviceName = "device_name"
    }
}

struct RegistrationResponse: nonisolated Decodable, Sendable {
    struct RegistrationData: nonisolated Decodable, Sendable {
        let user: CurrentUser
        let token: String
    }

    let data: RegistrationData
}

struct UpdateProfileRequest: Encodable {
    let name: String
    let email: String
}

struct UpdatePasswordRequest: Encodable {
    let currentPassword: String
    let password: String
    let passwordConfirmation: String

    enum CodingKeys: String, CodingKey {
        case password
        case currentPassword = "current_password"
        case passwordConfirmation = "password_confirmation"
    }
}

struct DeleteAccountRequest: Encodable {
    let currentPassword: String

    enum CodingKeys: String, CodingKey {
        case currentPassword = "current_password"
    }
}

struct PasswordResetRequest: Encodable {
    let email: String
}

struct RegenerateAnswerAudioRequest: Encodable, Equatable, Sendable {
    let answerAudioVoiceId: String?
    let answerAudioTextOverride: String?
}

struct RegenerateImageRequest: Encodable, Equatable, Sendable {
    let imagePrompt: String
    let imageRole: String
}

enum StudyCardCreationKind: String, nonisolated Codable, CaseIterable, Identifiable, Sendable {
    case textRecognition = "text-recognition"
    case audioRecognition = "audio-recognition"
    case productionText = "production-text"
    case productionImage = "production-image"
    case cloze

    var id: String { rawValue }

    var title: String {
        switch self {
        case .textRecognition: "Text recognition"
        case .audioRecognition: "Audio recognition"
        case .productionText: "Text production"
        case .productionImage: "Image production"
        case .cloze: "Cloze"
        }
    }

    var cardType: StudyCardDraft.CardType {
        switch self {
        case .textRecognition, .audioRecognition: .recognition
        case .productionText, .productionImage: .production
        case .cloze: .cloze
        }
    }

    var defaultImagePlacement: StudyCardDraft.ImagePlacement {
        switch self {
        case .productionImage: .prompt
        case .cloze: .both
        case .textRecognition, .audioRecognition, .productionText: .none
        }
    }
}

// learning-os resolves these ConvoLab compatibility resources directly, so
// card-draft list, detail, mutation, and preview responses are intentionally
// decoded without APIEnvelope.
struct StudyManualCardDraft: nonisolated Codable, Identifiable, Equatable, Sendable {
    let id: String
    let status: String
    let committedCardId: String?
    let creationKind: StudyCardCreationKind
    let cardType: String
    let prompt: JSONValue
    let answer: JSONValue
    let imagePlacement: StudyCardDraft.ImagePlacement
    let imagePrompt: String?
    let previewAudio: JSONValue?
    let previewAudioRole: String?
    let previewImage: JSONValue?
    let errorMessage: String?
    let createdAt: Date
    let updatedAt: Date
}

struct StudyManualCardDraftListResponse: nonisolated Codable, Sendable {
    let drafts: [StudyManualCardDraft]
    let total: Int?
    let limit: Int
    let nextCursor: String?
}

struct CreateStudyManualCardDraftRequest: Codable, Equatable, Sendable {
    let id: String
    let creationKind: StudyCardCreationKind
    let cardType: String
    let prompt: JSONValue
    let answer: JSONValue
    let imagePlacement: StudyCardDraft.ImagePlacement
    let imagePrompt: String?
}

struct UpdateStudyManualCardDraftRequest: Encodable, Equatable, Sendable {
    let prompt: JSONValue
    let answer: JSONValue
    let imagePlacement: StudyCardDraft.ImagePlacement
    let imagePrompt: String?
    let previewAudio: JSONValue
    let previewAudioRole: JSONValue
    let previewImage: JSONValue
}

struct StudyCardDraftPreviewAudioResponse: nonisolated Codable, Sendable {
    let previewAudio: JSONValue?
    let previewAudioRole: String?
}

struct StudyCardDraftImageResponse: nonisolated Codable, Sendable {
    let previewImage: JSONValue
    let imagePrompt: String
    let imagePlacement: StudyCardDraft.ImagePlacement
}

struct CreateCardFromStudyManualDraftRequest: Codable, Equatable, Sendable {
    let id: String
}

struct StudySession: nonisolated Codable, Sendable {
    let overview: StudyOverview
    let cards: [StudyCard]
}

struct StudySessionResponse: nonisolated Decodable, Sendable {
    let session: StudySession

    private enum CodingKeys: String, CodingKey {
        case data
        case overview
        case cards
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.data) {
            session = try container.decode(StudySession.self, forKey: .data)
        } else {
            session = try StudySession(from: decoder)
        }
    }
}

struct StudyOfflineReserve: nonisolated Decodable, Sendable {
    let cards: [StudyCard]
    let reserveDays: Int
    let generatedAt: Date
    let horizonEndsAt: Date

    enum CodingKeys: String, CodingKey {
        // The Study compatibility controller emits these fields in camel case.
        case cards
        case reserveDays = "reserveDays"
        case generatedAt = "generatedAt"
        case horizonEndsAt = "horizonEndsAt"
    }

    var metadata: StudyOfflineReserveMetadata {
        StudyOfflineReserveMetadata(
            reserveDays: reserveDays,
            generatedAt: generatedAt,
            horizonEndsAt: horizonEndsAt
        )
    }
}

struct StudyOfflineReserveMetadata: nonisolated Codable, Equatable, Sendable {
    let reserveDays: Int
    let generatedAt: Date
    let horizonEndsAt: Date
}

struct SyncFeedPage: nonisolated Decodable, Sendable {
    struct Entry: nonisolated Decodable, Sendable {
        let checkpoint: Int64
        let resourceId: String
        let operation: String

        enum CodingKeys: String, CodingKey {
            case checkpoint, operation
            case resourceId = "resource_id"
        }
    }

    struct Metadata: nonisolated Decodable, Sendable {
        let nextCheckpoint: Int64
        let hasMore: Bool

        enum CodingKeys: String, CodingKey {
            case nextCheckpoint = "next_checkpoint"
            case hasMore = "has_more"
        }
    }

    let data: [Entry]
    let meta: Metadata
}

struct StudyCardBatchRequest: Encodable, Sendable {
    let ids: [String]
}

struct StudyCardBatchResponse: nonisolated Decodable, Sendable {
    let cards: [StudyCard]
}

struct StudyCardPresentationV1: nonisolated Codable, Hashable, Sendable {
    struct MediaReference: nonisolated Codable, Hashable, Sendable {
        private enum CodingKeys: String, CodingKey {
            case id
            case filename
            case url
            case mediaKind
            case source
        }

        let id: String?
        let filename: String?
        let url: String?
        let mediaKind: String?
        let source: String?

        nonisolated init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            filename = try container.decodeIfPresent(String.self, forKey: .filename)
            url = try container.decodeIfPresent(String.self, forKey: .url)
            mediaKind = try container.decodeIfPresent(String.self, forKey: .mediaKind)
            source = try container.decodeIfPresent(String.self, forKey: .source)
        }
    }

    struct PitchAccent: nonisolated Codable, Hashable, Sendable {
        private enum CodingKeys: String, CodingKey {
            case status
            case expression
            case reading
            case pitchNum
            case morae
            case pattern
            case patternName
            case source
            case resolvedBy
        }

        // A v1 pitch payload is present only after server resolution; other statuses
        // are contract drift and intentionally fail the known-version decode.
        private enum Status: String, nonisolated Codable {
            case resolved
        }

        private let status: Status
        let expression: String
        let reading: String
        let pitchNum: Int?
        let morae: [String]
        let pattern: [Int]
        let patternName: String
        let source: String?
        let resolvedBy: String?

        nonisolated init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(Status.self, forKey: .status)
            expression = try container.decode(String.self, forKey: .expression)
            reading = try container.decode(String.self, forKey: .reading)
            pitchNum = try container.decodeIfPresent(Int.self, forKey: .pitchNum)
            morae = try container.decode([String].self, forKey: .morae)
            pattern = try container.decode([Int].self, forKey: .pattern)
            patternName = try container.decode(String.self, forKey: .patternName)
            source = try container.decodeIfPresent(String.self, forKey: .source)
            resolvedBy = try container.decodeIfPresent(String.self, forKey: .resolvedBy)

            guard
                !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !patternName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !morae.isEmpty,
                morae.count == pattern.count,
                morae.allSatisfy({
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }),
                pattern.allSatisfy({ $0 == 0 || $0 == 1 })
            else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Resolved pitch accent was malformed."
                ))
            }
        }
    }

    struct Front: nonisolated Codable, Hashable, Sendable {
        enum Mode: String, nonisolated Codable, Hashable, Sendable {
            case text
            case media
            case cloze
        }

        struct Media: nonisolated Codable, Hashable, Sendable {
            let audio: MediaReference?
            let image: MediaReference?
        }

        let mode: Mode
        let text: String?
        let ruby: String?
        let hint: String?
        let media: Media
        let autoplayAudio: Bool
    }

    struct Answer: nonisolated Codable, Hashable, Sendable {
        struct Text: nonisolated Codable, Hashable, Sendable {
            let text: String?
            let ruby: String?
        }

        struct Sentences: nonisolated Codable, Hashable, Sendable {
            let japanese: Text
            let english: Text
        }

        struct Media: nonisolated Codable, Hashable, Sendable {
            let image: MediaReference?
        }

        let heading: String?
        let ruby: String?
        let restored: String?
        let meaning: String?
        let sentences: Sentences
        let notes: [String]
        let media: Media
        let audio: MediaReference?
        let pitchAccent: PitchAccent?
    }

    let version: Int
    let front: Front
    let answer: Answer
}

struct StudyCard: nonisolated Codable, Identifiable, Hashable, Sendable {
    private struct PresentationVersion: nonisolated Decodable {
        let version: Int
    }

    struct State: nonisolated Codable, Hashable, Sendable {
        let dueAt: Date?
        let introducedAt: Date?
        let failedAt: Date?
        let queueState: String
        let scheduler: JSONValue?
        let source: JSONValue
    }

    private struct ProgressionFieldPresence: nonisolated Hashable, Sendable {
        let variantGroupId: Bool
        let variantStatus: Bool

        // Payload field presence affects compatibility reconciliation, not the
        // semantic identity of an otherwise identical card.
        nonisolated static func == (lhs: Self, rhs: Self) -> Bool { true }

        nonisolated func hash(into hasher: inout Hasher) {}
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case syncId
        case noteId
        case revision
        case cardType
        case prompt
        case answer
        case presentation
        case state
        case answerAudioSource
        case masteryLevel
        case variantGroupId
        case variantStatus
        case introductionCohortId
        case selectionPolicy
        case priorityUntil
        case introductionAvailableAt
        case createdAt
        case updatedAt
    }

    let id: String
    let syncId: String?
    let noteId: String?
    // Nil only for payloads cached before the revision contract shipped.
    let revision: Int?
    let cardType: String
    let prompt: JSONValue
    let answer: JSONValue
    let serverPresentation: StudyCardPresentationV1?
    let state: State
    let answerAudioSource: String?
    let masteryLevel: String?
    let variantGroupId: String?
    let variantStatus: String?
    let introductionCohortId: String?
    let selectionPolicy: String?
    let priorityUntil: Date?
    let introductionAvailableAt: Date?
    let createdAt: Date
    let updatedAt: Date
    private let progressionFieldPresence: ProgressionFieldPresence

    init(
        id: String,
        syncId: String? = nil,
        noteId: String?,
        revision: Int? = nil,
        cardType: String,
        prompt: JSONValue,
        answer: JSONValue,
        serverPresentation: StudyCardPresentationV1? = nil,
        state: State,
        answerAudioSource: String?,
        masteryLevel: String? = nil,
        variantGroupId: String? = nil,
        variantStatus: String? = nil,
        introductionCohortId: String? = nil,
        selectionPolicy: String? = nil,
        priorityUntil: Date? = nil,
        introductionAvailableAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.syncId = syncId
        self.noteId = noteId
        self.revision = revision
        self.cardType = cardType
        self.prompt = prompt
        self.answer = answer
        self.serverPresentation = serverPresentation
        self.state = state
        self.answerAudioSource = answerAudioSource
        self.masteryLevel = masteryLevel
        self.variantGroupId = variantGroupId
        self.variantStatus = variantStatus
        self.introductionCohortId = introductionCohortId
        self.selectionPolicy = selectionPolicy
        self.priorityUntil = priorityUntil
        self.introductionAvailableAt = introductionAvailableAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        progressionFieldPresence = .init(
            variantGroupId: true,
            variantStatus: true
        )
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        syncId = try container.decodeIfPresent(String.self, forKey: .syncId)
        noteId = try container.decodeIfPresent(String.self, forKey: .noteId)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision)
        cardType = try container.decode(String.self, forKey: .cardType)
        prompt = try container.decode(JSONValue.self, forKey: .prompt)
        answer = try container.decode(JSONValue.self, forKey: .answer)
        if let version = try container.decodeIfPresent(
            PresentationVersion.self,
            forKey: .presentation
        ), version.version == 1 {
            serverPresentation = try container.decode(
                StudyCardPresentationV1.self,
                forKey: .presentation
            )
        } else {
            // Missing and future presentation versions intentionally use the raw
            // prompt/answer compatibility renderer.
            serverPresentation = nil
        }
        state = try container.decode(State.self, forKey: .state)
        answerAudioSource = try container.decodeIfPresent(
            String.self,
            forKey: .answerAudioSource
        )
        masteryLevel = try container.decodeIfPresent(String.self, forKey: .masteryLevel)
        variantGroupId = try container.decodeIfPresent(String.self, forKey: .variantGroupId)
        variantStatus = try container.decodeIfPresent(String.self, forKey: .variantStatus)
        introductionCohortId = try container.decodeIfPresent(
            String.self,
            forKey: .introductionCohortId
        )
        selectionPolicy = try container.decodeIfPresent(String.self, forKey: .selectionPolicy)
        priorityUntil = try container.decodeIfPresent(Date.self, forKey: .priorityUntil)
        introductionAvailableAt = try container.decodeIfPresent(
            Date.self,
            forKey: .introductionAvailableAt
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        progressionFieldPresence = .init(
            variantGroupId: container.contains(.variantGroupId),
            variantStatus: container.contains(.variantStatus)
        )
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(syncId, forKey: .syncId)
        try container.encodeIfPresent(noteId, forKey: .noteId)
        try container.encodeIfPresent(revision, forKey: .revision)
        try container.encode(cardType, forKey: .cardType)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(answer, forKey: .answer)
        try container.encodeIfPresent(serverPresentation, forKey: .presentation)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(answerAudioSource, forKey: .answerAudioSource)
        try container.encodeIfPresent(masteryLevel, forKey: .masteryLevel)
        try container.encode(variantGroupId, forKey: .variantGroupId)
        try container.encode(variantStatus, forKey: .variantStatus)
        try container.encodeIfPresent(introductionCohortId, forKey: .introductionCohortId)
        try container.encodeIfPresent(selectionPolicy, forKey: .selectionPolicy)
        try container.encodeIfPresent(priorityUntil, forKey: .priorityUntil)
        try container.encodeIfPresent(
            introductionAvailableAt,
            forKey: .introductionAvailableAt
        )
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    var reviewCardID: String { syncId ?? id }

    func resolvedVariantGroupId(fallingBackTo fallback: String?) -> String? {
        progressionFieldPresence.variantGroupId ? variantGroupId : fallback
    }

    func resolvedVariantStatus(fallingBackTo fallback: String?) -> String? {
        progressionFieldPresence.variantStatus ? variantStatus : fallback
    }

    var includesProgressionMetadataProjection: Bool {
        progressionFieldPresence.variantGroupId && progressionFieldPresence.variantStatus
    }

    func resolvingProgressionMetadata(fallingBackTo fallback: StudyCard) -> Self {
        guard !includesProgressionMetadataProjection else { return self }
        return Self(
            id: id,
            syncId: syncId,
            noteId: noteId,
            revision: revision,
            cardType: cardType,
            prompt: prompt,
            answer: answer,
            serverPresentation: serverPresentation,
            state: state,
            answerAudioSource: answerAudioSource,
            masteryLevel: masteryLevel,
            variantGroupId: resolvedVariantGroupId(fallingBackTo: fallback.variantGroupId),
            variantStatus: resolvedVariantStatus(fallingBackTo: fallback.variantStatus),
            introductionCohortId: introductionCohortId,
            selectionPolicy: selectionPolicy,
            priorityUntil: priorityUntil,
            introductionAvailableAt: introductionAvailableAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func replacingIdentity(id: String, syncId: String?) -> Self {
        Self(
            id: id,
            syncId: syncId,
            noteId: noteId,
            revision: revision,
            cardType: cardType,
            prompt: prompt,
            answer: answer,
            serverPresentation: serverPresentation,
            state: state,
            answerAudioSource: answerAudioSource,
            masteryLevel: masteryLevel,
            variantGroupId: variantGroupId,
            variantStatus: variantStatus,
            introductionCohortId: introductionCohortId,
            selectionPolicy: selectionPolicy,
            priorityUntil: priorityUntil,
            introductionAvailableAt: introductionAvailableAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func replacingVariantStatus(_ variantStatus: String?) -> Self {
        Self(
            id: id,
            syncId: syncId,
            noteId: noteId,
            revision: revision,
            cardType: cardType,
            prompt: prompt,
            answer: answer,
            serverPresentation: serverPresentation,
            state: state,
            answerAudioSource: answerAudioSource,
            masteryLevel: masteryLevel,
            variantGroupId: variantGroupId,
            variantStatus: variantStatus,
            introductionCohortId: introductionCohortId,
            selectionPolicy: selectionPolicy,
            priorityUntil: priorityUntil,
            introductionAvailableAt: introductionAvailableAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    var promptText: String {
        if let serverPresentation {
            if let heading = auxiliaryPlainText(serverPresentation.front.ruby)
                ?? auxiliaryPlainText(serverPresentation.front.text) {
                return heading
            }
            if serverPresentation.front.mode == .media {
                return auxiliaryPlainText(serverPresentation.answer.ruby)
                    ?? auxiliaryPlainText(serverPresentation.answer.heading)
                    ?? auxiliaryDisplayText(serverPresentation.answer.meaning)
                    ?? "Media prompt"
            }
            return "Study card"
        }
        if let heading = presentation.front.heading {
            return StudyRubyDocument.parse(heading, knownKanji: []).plainText
        }
        if cardType == "cloze" {
            return "Study card"
        }
        if presentation.front.audioURL != nil || presentation.front.imageURL != nil {
            return presentation.back.heading
                ?? presentation.back.textBlocks.first { $0.role == .meaning }?.text
                ?? "Media prompt"
        }
        return prompt.preferredText ?? answer.preferredText ?? "Study card"
    }

    var answerText: String {
        if let serverPresentation {
            let heading = auxiliaryPlainText(serverPresentation.answer.ruby)
                ?? auxiliaryPlainText(serverPresentation.answer.heading)
            let restored = auxiliaryPlainText(serverPresentation.answer.restored)
            let meaning = auxiliaryDisplayText(serverPresentation.answer.meaning)
            if serverPresentation.front.mode == .cloze {
                return heading ?? restored ?? meaning ?? "No answer text"
            }
            return meaning ?? heading ?? restored ?? "No answer text"
        }
        if cardType == "cloze" {
            return presentation.back.heading.map {
                StudyRubyDocument.parse($0, knownKanji: []).plainText
            }
                ?? answer.firstNonEmptyString(for: ["restoredText", "expression", "text", "meaning"])
                ?? answer.preferredText
                ?? "No answer text"
        }
        return answer.firstNonEmptyString(for: ["meaning", "translation", "text", "answerText"])
            ?? answer.preferredText
            ?? "No answer text"
    }

    var answerDetailText: String? {
        if let serverPresentation {
            guard serverPresentation.front.mode == .cloze else { return nil }
            let detail = auxiliaryDisplayText(serverPresentation.answer.meaning)
            return detail == answerText ? nil : detail
        }
        guard cardType == "cloze" else { return nil }
        let detail = answer.firstNonEmptyString(for: ["meaning", "translation"])
        return detail == answerText ? nil : detail
    }

    var mediaURLs: [URL] {
        guard serverPresentation != nil else {
            return rawMediaURLs
        }
        let projected = presentation
        return [
            projected.front.audioURL,
            projected.front.imageURL,
            projected.back.audioURL,
            projected.back.imageURL,
        ].compactMap(\.self)
    }

    var rawMediaURLs: [URL] { prompt.mediaURLs + answer.mediaURLs }

    private func auxiliaryDisplayText(_ rawValue: String?) -> String? {
        guard let displayText = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !displayText.isEmpty
        else {
            return nil
        }
        return displayText
    }

    private func auxiliaryPlainText(_ rawValue: String?) -> String? {
        guard let displayText = auxiliaryDisplayText(rawValue) else { return nil }
        let plainText = StudyRubyDocument.parse(displayText, knownKanji: []).plainText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return plainText.isEmpty ? nil : plainText
    }

    func reviewSchedule(
        _ rating: ReviewRating,
        at reviewedAt: Date
    ) throws -> FSRSReviewSchedule {
        try FSRSReviewScheduler.schedule(
            schedulerState: state.scheduler,
            queueState: state.queueState,
            rating: rating,
            reviewedAt: reviewedAt
        )
    }

    func applyingReview(_ rating: ReviewRating, at reviewedAt: Date) throws -> StudyCard {
        let schedule = try reviewSchedule(rating, at: reviewedAt)
        return StudyCard(
            id: id,
            syncId: syncId,
            noteId: noteId,
            revision: revision,
            cardType: cardType,
            prompt: prompt,
            answer: answer,
            serverPresentation: serverPresentation,
            state: .init(
                dueAt: schedule.dueAt,
                introducedAt: state.introducedAt
                    ?? (state.queueState == "new" ? reviewedAt : nil),
                failedAt: rating == .again ? reviewedAt : nil,
                queueState: schedule.queueState,
                scheduler: schedule.schedulerState,
                source: state.source
            ),
            answerAudioSource: answerAudioSource,
            variantGroupId: variantGroupId,
            variantStatus: variantStatus,
            introductionCohortId: introductionCohortId,
            selectionPolicy: selectionPolicy,
            priorityUntil: priorityUntil,
            introductionAvailableAt: introductionAvailableAt,
            createdAt: createdAt,
            updatedAt: reviewedAt
        )
    }

    func isEligibleForOfflineStudy(at date: Date) -> Bool {
        guard isProgressionAvailable else { return false }
        guard ["learning", "review", "relearning"].contains(state.queueState) else {
            return false
        }
        guard let dueAt = state.dueAt else { return false }
        return dueAt <= date
    }

    var belongsToLearningProgression: Bool {
        variantGroupId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var isProgressionAvailable: Bool {
        variantStatus == nil
            || variantStatus?.localizedCaseInsensitiveCompare("available") == .orderedSame
    }
}

struct StudyNewCardQueueItem: nonisolated Codable, Identifiable, Equatable, Sendable {
    let id: String
    let noteId: String
    let cardType: String
    let displayText: String
    let meaning: String?
    let queuePosition: Int?
    let createdAt: Date
    let updatedAt: Date
}

struct StudyNewCardQueueResponse: nonisolated Codable, Equatable, Sendable {
    let items: [StudyNewCardQueueItem]
    let total: Int
    let limit: Int
    let nextCursor: String?
}

struct StudyIntroductionCohort: nonisolated Codable, Equatable, Sendable {
    let id: String
    let sourceKind: String
    let label: String?
    let priorityUntil: Date
    let cards: [StudyCard]
    let createdAt: Date
    let updatedAt: Date
}

struct CreateStudyLessonFollowupCohortRequest: nonisolated Encodable, Equatable, Sendable {
    let cohortId: String
    let cardIds: [String]
    let label: String?
}

struct StudyCardListResponse: nonisolated Codable, Equatable, Sendable {
    let items: [StudyCard]
    let limit: Int
    let nextCursor: String?
}

enum StudyLearningItemStageStatus: String, nonisolated Codable, Equatable, Sendable {
    case locked
    case available
    case retired
    case unknown

    nonisolated init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum StudyLearningPathUnlockRequirement: String, nonisolated Codable, Equatable, Hashable, Sendable {
    case successfulRetrieval = "successful_retrieval"
    case guru
    case master
    case unknown

    nonisolated init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static var selectableCases: [Self] {
        [.successfulRetrieval, .guru, .master]
    }

    var title: String {
        switch self {
        case .successfulRetrieval: "2 successful reviews"
        case .guru: "Guru"
        case .master: "Master"
        case .unknown: "Unknown"
        }
    }

    var helpText: String {
        switch self {
        case .successfulRetrieval:
            "Unlock after two Good or Easy reviews."
        case .guru:
            "Unlock once this card reaches Guru and the next review is Good or Easy."
        case .master:
            "Unlock once this card reaches Master and the next review is Good or Easy."
        case .unknown:
            "This path uses a requirement added by a newer version of ConvoLab."
        }
    }
}

struct StudyLearningPathCard: nonisolated Codable, Identifiable, Equatable, Sendable {
    let id: String
    let sourceNoteId: String?
    let cardType: String
    let frontText: String?
    let backText: String?
    let promptJSON: JSONValue?
    let answerJSON: JSONValue?
    let variantStage: Int?
    let variantStatus: StudyLearningItemStageStatus?
    let variantUnlockRequirement: StudyLearningPathUnlockRequirement?

    enum CodingKeys: String, CodingKey {
        case id
        case sourceNoteId = "source_note_id"
        case cardType = "card_type"
        case frontText = "front_text"
        case backText = "back_text"
        case promptJSON = "prompt_json"
        case answerJSON = "answer_json"
        case variantStage = "variant_stage"
        case variantStatus = "variant_status"
        case variantUnlockRequirement = "variant_unlock_requirement"
    }

    var displayText: String {
        promptJSON?.firstNonEmptyString(
            for: ["clozeDisplayText", "cueText", "clozeText", "text"]
        ) ?? normalized(frontText) ?? id
    }

    var meaning: String? {
        answerJSON?.firstNonEmptyString(
            for: ["meaning", "translation", "sentenceEn", "text"]
        ) ?? normalized(backText)
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct StudyLearningPathStage: nonisolated Codable, Identifiable, Equatable, Sendable {
    let number: Int?
    let cards: [StudyLearningPathCard]

    nonisolated var id: String {
        number.map { "stage:\($0)" }
            ?? "cards:\(cards.map(\.id).joined(separator: ","))"
    }
}

struct StudyLearningPath: nonisolated Codable, Equatable, Sendable {
    let groupId: String?
    let anchorCardId: String
    let stages: [StudyLearningPathStage]

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case anchorCardId = "anchor_card_id"
        case stages
    }
}

struct LinkStudyLearningPathSuccessorRequest: Encodable, Equatable, Sendable {
    let successorCardId: String
    let unlockRequirement: StudyLearningPathUnlockRequirement

    enum CodingKeys: String, CodingKey {
        case successorCardId = "successor_card_id"
        case unlockRequirement = "unlock_requirement"
    }
}

struct StudyLearningItemCard: nonisolated Codable, Identifiable, Equatable, Sendable {
    let id: String
    let syncId: String
    let noteId: String?
    let cardType: String
    let displayText: String
    let meaning: String?
    let variantKind: String?
}

struct StudyLearningItemStage: nonisolated Codable, Identifiable, Equatable, Sendable {
    let number: Int?
    let status: StudyLearningItemStageStatus?
    let cardCount: Int
    let representativeCard: StudyLearningItemCard
    let cards: [StudyLearningItemCard]

    nonisolated var id: String {
        number.map { "stage:\($0)" }
            ?? "card:\(representativeCard.syncId.lowercased())"
    }
}

struct StudyLearningItem: nonisolated Codable, Identifiable, Equatable, Sendable {
    let id: String
    let groupId: String?
    let representativeCard: StudyLearningItemCard
    let currentStageNumber: Int?
    let stageCount: Int
    let cardCount: Int
    let retiredStageCount: Int
    let transferDemonstrated: Bool
    let stages: [StudyLearningItemStage]
}

struct StudyLearningItemListResponse: nonisolated Codable, Equatable, Sendable {
    let items: [StudyLearningItem]
    let limit: Int
    let nextCursor: String?
}

struct ReorderStudyNewCardQueueRequest: Encodable, Equatable, Sendable {
    let cardIds: [String]
}

enum ReviewRating: String, Codable, CaseIterable, Sendable {
    case again
    case hard
    case good
    case easy
}

struct ReviewBatchRequest: Codable {
    struct Event: Codable {
        let id: String
        let cardID: String
        let rating: ReviewRating
        let reviewedAt: Date
        let durationMilliseconds: Int?
        let clientEventID: String
        let deviceID: String
        let clientCreatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id, rating
            case cardID = "card_id"
            case reviewedAt = "reviewed_at"
            case durationMilliseconds = "duration_ms"
            case clientEventID = "client_event_id"
            case deviceID = "device_id"
            case clientCreatedAt = "client_created_at"
        }

        func encode(to encoder: Encoder) throws {
            // Review dates bypass APIClient's whole-second strategy so the wire
            // event retains the same canonical instant as the local projection.
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(cardID, forKey: .cardID)
            try container.encode(rating, forKey: .rating)
            try container.encode(
                ISO8601Milliseconds.string(from: reviewedAt),
                forKey: .reviewedAt
            )
            try container.encodeIfPresent(durationMilliseconds, forKey: .durationMilliseconds)
            try container.encode(clientEventID, forKey: .clientEventID)
            try container.encode(deviceID, forKey: .deviceID)
            try container.encode(
                ISO8601Milliseconds.string(from: clientCreatedAt),
                forKey: .clientCreatedAt
            )
        }
    }

    let events: [Event]
}

struct StudyMediaBatchRequest: Encodable {
    let ids: [String]
}

struct StudyMediaBatchResponse: nonisolated Decodable, Sendable {
    struct Item: nonisolated Decodable, Sendable {
        let id: String
        let mimeType: String
        let data: Data
    }

    let items: [Item]
}

struct UndoStudyReviewRequest: Encodable {
    let reviewLogId: String
    let timeZone: String
}

struct UndoStudyReviewResponse: nonisolated Decodable, Sendable {
    let reviewLogId: String
    let card: StudyCard
    let overview: StudyOverview
}

enum StudyCardActionName: String, nonisolated Codable, Sendable {
    case suspend
    case unsuspend
    case forget
    case setDue = "set_due"
}

enum StudyCardSetDueMode: String, nonisolated Codable, Sendable {
    case now
    case tomorrow
    case customDate = "custom_date"
}

struct StudyCardActionRequest: Codable, Equatable, Sendable {
    let action: StudyCardActionName
    let mode: StudyCardSetDueMode?
    let dueAt: Date?
    let timeZone: String?
}

struct StudyCardActionResponse: nonisolated Codable, Sendable {
    let card: StudyCard
    let overview: StudyOverview
}

struct DailyAudioPractice: nonisolated Codable, Identifiable, Sendable {
    let id: String
    let practiceDate: String
    let status: String
    let targetDurationMinutes: Int
    let errorMessage: String?
    let createdAt: Date
    let updatedAt: Date
    let tracks: [DailyAudioTrack]
}

struct DailyAudioPracticePage: nonisolated Codable, Sendable {
    let items: [DailyAudioPractice]
    let total: Int
    let limit: Int
    let nextCursor: String?

    init(
        items: [DailyAudioPractice],
        total: Int,
        limit: Int,
        nextCursor: String?
    ) {
        self.items = items
        self.total = total
        self.limit = limit
        self.nextCursor = nextCursor
    }

    nonisolated init(from decoder: Decoder) throws {
        if var legacy = try? decoder.unkeyedContainer() {
            var practices: [DailyAudioPractice] = []
            while !legacy.isAtEnd {
                practices.append(try legacy.decode(DailyAudioPractice.self))
            }
            items = practices
            total = practices.count
            limit = practices.count
            nextCursor = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([DailyAudioPractice].self, forKey: .items)
        total = try container.decode(Int.self, forKey: .total)
        limit = try container.decode(Int.self, forKey: .limit)
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

struct DailyAudioTrack: nonisolated Codable, Identifiable, Sendable {
    let id: String
    let practiceId: String
    let mode: String
    let status: String
    let title: String
    let sortOrder: Int
    let scriptUnitsJson: [DailyAudioScriptUnit]?
    let audioUrl: String?
    let timingData: [DailyAudioTiming]?
    let approxDurationSeconds: Double?
    let updatedAt: Date

    var formattedDuration: String {
        guard let approxDurationSeconds,
              approxDurationSeconds.isFinite,
              approxDurationSeconds >= 0
        else {
            return "Length unavailable"
        }
        let roundedSeconds = Int(approxDurationSeconds.rounded())
        let minutes = roundedSeconds / 60
        let seconds = roundedSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }

    var revisionMilliseconds: Int64 {
        Int64((updatedAt.timeIntervalSince1970 * 1_000).rounded())
    }

    static func latest(
        matching track: DailyAudioTrack,
        in practices: [DailyAudioPractice]
    ) -> DailyAudioTrack {
        practices.lazy.flatMap(\.tracks).first { $0.id == track.id } ?? track
    }

    init(
        id: String,
        practiceId: String,
        mode: String,
        status: String,
        title: String,
        sortOrder: Int,
        scriptUnitsJson: [DailyAudioScriptUnit]? = nil,
        audioUrl: String?,
        timingData: [DailyAudioTiming]? = nil,
        approxDurationSeconds: Double?,
        updatedAt: Date
    ) {
        self.id = id
        self.practiceId = practiceId
        self.mode = mode
        self.status = status
        self.title = title
        self.sortOrder = sortOrder
        self.scriptUnitsJson = scriptUnitsJson
        self.audioUrl = audioUrl
        self.timingData = timingData
        self.approxDurationSeconds = approxDurationSeconds
        self.updatedAt = updatedAt
    }
}

struct DailyAudioScriptUnit: nonisolated Codable, Equatable, Sendable {
    let type: String
    let text: String?
    let reading: String?
    let translation: String?

    nonisolated init(
        type: String,
        text: String?,
        reading: String?,
        translation: String?
    ) {
        self.type = type
        self.text = text
        self.reading = reading
        self.translation = translation
    }
}

struct DailyAudioTiming: nonisolated Codable, Equatable, Sendable {
    let unitIndex: Int
    let startTime: Double
    let endTime: Double

    nonisolated init(
        unitIndex: Int,
        startTime: Double,
        endTime: Double
    ) {
        self.unitIndex = unitIndex
        self.startTime = startTime
        self.endTime = endTime
    }
}

struct CreateDailyAudioRequest: Encodable {
    let timeZone: String
    let targetDurationMinutes: Int
}

struct CreateStudyCardRequest: Codable {
    let id: String
    let cardType: String
    let prompt: JSONValue
    let answer: JSONValue
}

struct UpdateStudyCardRequest: Codable {
    let prompt: JSONValue
    let answer: JSONValue
    // Nil preserves legacy queued edits as unconditional writes; newly projected
    // edits from authoritative cards always carry the server revision.
    let expectedRevision: Int?

    private enum CodingKeys: String, CodingKey {
        case prompt
        case answer
        case expectedRevision
    }

    init(
        prompt: JSONValue,
        answer: JSONValue,
        expectedRevision: Int? = nil
    ) {
        self.prompt = prompt
        self.answer = answer
        self.expectedRevision = expectedRevision
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decode(JSONValue.self, forKey: .prompt)
        answer = try container.decode(JSONValue.self, forKey: .answer)
        // Outbox rows written by earlier app versions predate optimistic revisions.
        // Preserve that as unknown so the backend can accept the legacy edit
        // without mistaking a migration artifact for a concurrent write.
        expectedRevision = try container.decodeIfPresent(Int.self, forKey: .expectedRevision)
    }
}

struct KnownKanjiSnapshot: nonisolated Codable, Equatable, Sendable {
    struct WaniKaniStatus: nonisolated Codable, Equatable, Sendable {
        struct TransferBridgeStatus: nonisolated Codable, Equatable, Sendable {
            let enabled: Bool
            let importedVocabularyCount: Int
            let pendingVocabularyCount: Int
            let failedVocabularyCount: Int
            let lastImportedAt: Date?

            static let disabled = TransferBridgeStatus(
                enabled: false,
                importedVocabularyCount: 0,
                pendingVocabularyCount: 0,
                failedVocabularyCount: 0,
                lastImportedAt: nil
            )
        }

        let connected: Bool
        let lastSyncedAt: Date?
        let reviewCount: Int?
        let reviewCountUpdatedAt: Date?
        let transferBridge: TransferBridgeStatus?

        init(
            connected: Bool,
            lastSyncedAt: Date?,
            reviewCount: Int? = nil,
            reviewCountUpdatedAt: Date? = nil,
            transferBridge: TransferBridgeStatus? = nil
        ) {
            self.connected = connected
            self.lastSyncedAt = lastSyncedAt
            self.reviewCount = reviewCount
            self.reviewCountUpdatedAt = reviewCountUpdatedAt
            self.transferBridge = transferBridge
        }
    }

    let version: Int
    let kanji: [String]
    let manualKanji: [String]
    let wanikani: WaniKaniStatus
}

struct ConnectWaniKaniRequest: Encodable {
    let apiToken: String
}

struct UpdateWaniKaniTransferBridgeRequest: Encodable {
    let enabled: Bool
}

struct WaniKaniSyncResult: nonisolated Decodable, Equatable, Sendable {
    let added: Int
    let effectiveTotal: Int
    let version: Int
}
