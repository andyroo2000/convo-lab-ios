import SwiftUI

struct StudyCardProgress: Equatable {
    let completed: Int
    let total: Int

    static func batch(total: Int, remaining: Int) -> Self {
        Self(completed: max(0, total - remaining), total: max(total, remaining))
    }

    static func review(reviewed: Set<String>, queued: Set<String>, due: Int) -> Self {
        let completed = reviewed.subtracting(queued).count
        return Self(completed: completed, total: completed + max(due, queued.count))
    }
}

struct StudyCardProgressView: View {
    let progress: StudyCardProgress

    var body: some View {
        if progress.total > 0 {
            ProgressView(value: Double(progress.completed), total: Double(progress.total))
                .progressViewStyle(.linear)
                .tint(JournalBrandStyle.spine)
                .accessibilityLabel("Session progress")
                .accessibilityValue("\(progress.completed) of \(progress.total) complete")
        }
    }
}

struct StudyQueueCountsView: View {
    let failed: Int
    let remaining: Int

    var body: some View {
        HStack(spacing: 6) {
            Label(String(failed), systemImage: "arrow.counterclockwise")
                .foregroundStyle(Color(red: 0.62, green: 0.25, blue: 0.23))
            Text("·")
            Label(String(remaining), systemImage: "square.2.layers.3d")
        }
        .labelStyle(.titleAndIcon)
        .font(StudyWashiStyle.actionFont.weight(.semibold))
        .foregroundStyle(JournalBrandStyle.spine)
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(failed) failed, \(remaining) remaining")
    }
}
