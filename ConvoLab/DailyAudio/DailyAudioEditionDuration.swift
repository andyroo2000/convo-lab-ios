import Foundation

enum DailyAudioEditionDuration: Int, CaseIterable, Identifiable, Sendable {
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case fortyFiveMinutes = 45
    case sixtyMinutes = 60

    var id: Int { rawValue }

    var label: String { "\(rawValue) min" }

    static func available(
        for capabilities: StudyCapabilities.DailyAudio
    ) -> [Self] {
        let advertised = allCases.filter {
            capabilities.targetDurationMinutes.range.contains($0.rawValue)
        }
        return advertised.isEmpty ? allCases : advertised
    }

    static func preferred(
        for capabilities: StudyCapabilities.DailyAudio
    ) -> Self {
        let target = capabilities.targetDurationMinutes.default
        return available(for: capabilities).min {
            abs($0.rawValue - target) < abs($1.rawValue - target)
        } ?? .thirtyMinutes
    }
}
