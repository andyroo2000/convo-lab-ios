import Foundation

enum StorageMode: Equatable, Sendable {
    case persistent
    case temporary
}

enum StorageDomain: Equatable, Sendable {
    case study
    case studyTime
}

struct StorageStatus: Equatable, Sendable {
    let study: StorageMode
    let studyTime: StorageMode

    var isDegraded: Bool {
        study == .temporary || studyTime == .temporary
    }

    var warningMessage: String? {
        switch (study, studyTime) {
        case (.persistent, .persistent):
            nil
        case (.temporary, .persistent):
            "Study data is using temporary storage. Card and review changes are disabled until you relaunch the app."
        case (.persistent, .temporary):
            "Study time is using temporary storage. Recording and editing study time are disabled until you relaunch the app."
        case (.temporary, .temporary):
            "ConvoLab is using temporary storage. Card, review, and study-time changes are disabled until you relaunch the app."
        }
    }
}

struct StorageWriteUnavailableError: LocalizedError {
    let domain: StorageDomain

    var errorDescription: String? {
        switch domain {
        case .study:
            "Card and review changes are disabled because ConvoLab could not open persistent study storage. Relaunch the app to try again."
        case .studyTime:
            "Study-time changes are disabled because ConvoLab could not open persistent study-time storage. Relaunch the app to try again."
        }
    }
}
