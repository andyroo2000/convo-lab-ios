import SwiftUI

extension StudyActivityCategory {
    var chartColor: Color {
        switch self {
        case .review: Color(red: 54/255, green: 95/255, blue: 71/255)
        case .listen: Color(red: 113/255, green: 155/255, blue: 177/255)
        case .create: Color(red: 215/255, green: 174/255, blue: 86/255)
        case .immerse: Color(red: 129/255, green: 164/255, blue: 114/255)
        case .conversation: Color(red: 200/255, green: 121/255, blue: 97/255)
        case .writing: Color(red: 180/255, green: 153/255, blue: 191/255)
        case .wanikani: Color(red: 105/255, green: 103/255, blue: 142/255)
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
