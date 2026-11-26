import SwiftUI
import UIKit

struct MasteryReviewAnimation: View {
    enum Change: Equatable {
        case promotion, demotion

        init?(from: StudyMasteryLevel, to: StudyMasteryLevel) {
            guard from != to else { return nil }
            self = to.rank > from.rank ? .promotion : .demotion
        }

        func exitOffset(reduceMotion: Bool) -> CGFloat {
            self == .promotion && !reduceMotion ? -28 : 0
        }
    }

    let label: String
    let fromLevel: StudyMasteryLevel
    let toLevel: StudyMasteryLevel
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appearing = true
    @State private var leaving = false

    private var change: Change? { Change(from: fromLevel, to: toLevel) }

    var body: some View {
        Group {
            if let change {
                Text(toLevel.rawValue.capitalized)
                    .font(.custom("CrimsonPro-Regular", size: 21, relativeTo: .body).weight(.semibold))
                    .foregroundStyle(change == .promotion ? Color(red: 0.21, green: 0.42, blue: 0.25) : Color(red: 0.63, green: 0.24, blue: 0.22))
                    .opacity(leaving || (appearing && change == .demotion) ? 0 : 1)
                    .offset(y: leaving ? change.exitOffset(reduceMotion: reduceMotion) : 0)
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .accessibilityHidden(true)
        .task { await play() }
    }

    @MainActor
    private func play() async {
        guard let change else { onFinished(); return }
        let verb = change == .promotion ? "advanced" : "dropped"
        UIAccessibility.post(notification: .announcement, argument: "\(label) \(verb) to \(toLevel.rawValue.capitalized).")
        withAnimation(.easeInOut(duration: 0.21)) { appearing = false }
        let hold = change == .promotion ? 615 : 882
        let fade = 1_160 - hold
        do {
            try await Task.sleep(for: .milliseconds(hold))
            withAnimation(.easeInOut(duration: Double(fade) / 1_000)) { leaving = true }
            try await Task.sleep(for: .milliseconds(fade))
            onFinished()
        } catch { return }
    }

    static func color(for level: StudyMasteryLevel) -> Color {
        switch level {
        case .apprentice: return .pink
        case .guru: return .purple
        case .master: return .blue
        case .enlightened: return .orange
        case .burned: return .green
        }
    }

}
