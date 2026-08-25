import SwiftUI

extension StudyActivityCategory {
    var chartColor: Color {
        switch self {
        case .review: .blue
        case .listen: .cyan
        case .create: .orange
        case .immerse: .green
        case .conversation: .purple
        case .wanikani: .pink
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
