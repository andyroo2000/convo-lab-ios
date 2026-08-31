import AppIntents

struct StartSatoriReaderSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Satori Reader Session"
    static let description = IntentDescription(
        "Marks the beginning of a Satori Reader session for ConvoLab study-time tracking."
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        SatoriReaderTrackingStore.shared.recordStart()
        return .result()
    }
}

struct StopSatoriReaderSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Satori Reader Session"
    static let description = IntentDescription(
        "Marks the end of a Satori Reader session for ConvoLab study-time tracking."
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        SatoriReaderTrackingStore.shared.recordStop()
        return .result()
    }
}
