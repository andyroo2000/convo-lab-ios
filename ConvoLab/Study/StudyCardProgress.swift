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
            HStack(spacing: 12) {
                ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    .progressViewStyle(.linear)
                    .tint(StudyWashiStyle.green)
                Text("\(progress.completed) of \(progress.total) complete")
                    .font(.custom("CrimsonPro-Regular", size: 16, relativeTo: .subheadline))
                    .monospacedDigit()
                    .foregroundStyle(StudyWashiStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            .frame(maxWidth: 680)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Session progress")
            .accessibilityValue("\(progress.completed) of \(progress.total) complete")
        }
    }
}
