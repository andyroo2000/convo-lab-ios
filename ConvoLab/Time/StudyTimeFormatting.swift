import SwiftUI

extension StudyActivityCategory {
    var chartColor: Color {
        switch self {
        case .review: StudyTimePaper.color(0x365f47, 0x8fb99b)
        case .listen: StudyTimePaper.color(0x62879c, 0x719bb1)
        case .create: StudyTimePaper.color(0xab812e, 0xd7ae56)
        case .immerse: StudyTimePaper.color(0x6a895e, 0x81a472)
        case .conversation: StudyTimePaper.color(0xbc735d, 0xcf907c)
        case .writing: StudyTimePaper.color(0x9d7fa7, 0xb499bf)
        case .wanikani: StudyTimePaper.color(0x69678e, 0xaaa7cf)
        }
    }
}

func studyTimeCompactDuration(_ milliseconds: Int) -> String {
    let totalMinutes = max(0, milliseconds / 60_000)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours == 0 {
        return "\(minutes)m"
    }
    if minutes == 0 {
        return "\(hours)h"
    }
    return "\(hours)h \(minutes)m"
}

extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
