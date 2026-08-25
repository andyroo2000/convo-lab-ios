import Foundation

enum DailyAudioEditionDuration: Int, CaseIterable, Identifiable, Sendable {
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case fortyFiveMinutes = 45
    case sixtyMinutes = 60

    var id: Int { rawValue }

    var label: String { "\(rawValue) min" }
}
