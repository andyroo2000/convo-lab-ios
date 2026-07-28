import SwiftUI
import UIKit

struct MasteryReviewAnimation: View {
    let label: String
    let fromLevel: String
    let toLevel: String
    let passed: Bool
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var railOpacity = 0.0
    @State private var trackProgress = CGFloat.zero
    @State private var activeIndex = 0
    @State private var nodeScale = 1.0
    @State private var failureHaloScale = 0.2
    @State private var failureHaloOpacity = 0.0
    @State private var shakeOffset = 0.0

    private let levels = StudyMasteryLevel.allCases

    private var fromIndex: Int {
        StudyMasteryLevel(rawValue: fromLevel)?.rank ?? 0
    }

    private var toIndex: Int {
        StudyMasteryLevel(rawValue: toLevel)?.rank ?? fromIndex
    }

    private var announcement: String {
        Self.announcement(
            label: label,
            fromIndex: fromIndex,
            toIndex: toIndex,
            passed: passed
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let segmentWidth = Self.segmentWidth(for: geometry.size.width)
            let windowWidth = min(geometry.size.width * 0.84, 360)

            ZStack {
                masteryRail(segmentWidth: segmentWidth, windowWidth: windowWidth)
                    .frame(width: windowWidth, height: Self.railHeight)
                    .position(
                        x: geometry.size.width / 2,
                        y: Self.railCenterY
                    )
                    .opacity(railOpacity)

                Text(levels[activeIndex].rawValue.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(ConvoLabTheme.navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: windowWidth)
                    .position(
                        x: geometry.size.width / 2,
                        y: Self.levelNameCenterY
                    )
                    .opacity(railOpacity)
                    .accessibilityHidden(true)

                if reduceMotion {
                    Label(
                        Self.reducedMotionStatus(passed: passed),
                        systemImage: passed ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .font(.caption.weight(.bold))
                    .foregroundStyle(passed ? Color.green : Color.red)
                    .position(
                        x: geometry.size.width / 2,
                        y: Self.resultCenterY
                    )
                    .opacity(railOpacity)
                    .accessibilityHidden(true)
                }

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(announcement)
        .task(id: "\(label)|\(fromLevel)|\(toLevel)|\(passed)") {
            UIAccessibility.post(notification: .announcement, argument: announcement)
            await runAnimation()
        }
    }

    private func masteryRail(segmentWidth: CGFloat, windowWidth: CGFloat) -> some View {
        let totalWidth = segmentWidth * CGFloat(levels.count)
        let leadingOffset = windowWidth / 2
            - (CGFloat(fromIndex) + 0.5) * segmentWidth
            + trackProgress * CGFloat(fromIndex - toIndex) * segmentWidth
            + shakeOffset

        return ZStack {
            HStack(spacing: 0) {
                ForEach(Array(levels.enumerated()), id: \.element.rawValue) { index, level in
                    masterySegment(level: level, index: index)
                        .frame(width: segmentWidth, height: Self.railHeight)
                }
            }
            .frame(width: totalWidth, height: Self.railHeight)
            .position(
                x: leadingOffset + totalWidth / 2,
                y: Self.railHeight / 2
            )
        }
        .clipped()
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.12),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private func masterySegment(level: StudyMasteryLevel, index: Int) -> some View {
        let color = Self.color(for: level)
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(color)
                .frame(height: 5)
                .offset(y: Self.lineTop)

            if index == toIndex, !passed {
                Circle()
                    .stroke(Color.red.opacity(0.4), lineWidth: 4)
                    .frame(width: 30, height: 30)
                    .scaleEffect(failureHaloScale)
                    .opacity(failureHaloOpacity)
                    .offset(y: Self.failureHaloTop)
            }

            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
                .overlay {
                    Circle()
                        .stroke(ConvoLabTheme.cream, lineWidth: 4)
                }
                .scaleEffect(index == toIndex ? nodeScale : 1)
                .offset(y: Self.nodeTop)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static let feedbackLaneHeight = CGFloat(68)
    static let railHeight = CGFloat(68)
    static let railCenterY = CGFloat(34)
    static let levelNameCenterY = CGFloat(10)
    static let resultCenterY = CGFloat(58)
    static let lineTop = CGFloat(36)
    static let failureHaloTop = CGFloat(23)
    static let nodeTop = CGFloat(29)

    static func segmentWidth(for availableWidth: CGFloat) -> CGFloat {
        min(max(availableWidth * 0.48, 150), 190)
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

    static func announcement(
        label: String,
        fromIndex: Int,
        toIndex: Int,
        passed: Bool
    ) -> String {
        let destination = StudyMasteryLevel.allCases[toIndex].rawValue.capitalized

        if !passed {
            return fromIndex == toIndex
                ? "\(label) remains \(destination). Try again."
                : "\(label) dropped to \(destination)."
        }
        if toIndex > fromIndex {
            return "\(label) advanced to \(destination)."
        }
        if toIndex < fromIndex {
            return "\(label) is now \(destination)."
        }
        return "\(label) remains \(destination)."
    }

    static func reducedMotionStatus(passed: Bool) -> String {
        passed ? "Passed" : "Try again"
    }

    @MainActor
    private func runAnimation() async {
        activeIndex = fromIndex

        if reduceMotion {
            trackProgress = 1
            activeIndex = toIndex
            withAnimation(.easeOut(duration: 0.1)) {
                railOpacity = 1
            }
            guard await pause(for: .milliseconds(450)) else { return }
            withAnimation(.easeIn(duration: 0.15)) {
                railOpacity = 0
            }
            guard await pause(for: .milliseconds(155)) else { return }
            onFinished()
            return
        }

        withAnimation(.easeOut(duration: 0.12)) {
            railOpacity = 1
        }
        guard await pause(for: .milliseconds(220)) else { return }

        if fromIndex != toIndex {
            withAnimation(.timingCurve(0.18, 0.92, 0.3, 1, duration: 0.34)) {
                trackProgress = 1.06
            }
            guard await pause(for: .milliseconds(340)) else { return }
            withAnimation(.spring(response: 0.24, dampingFraction: 0.76)) {
                trackProgress = 1
            }
            guard await pause(for: .milliseconds(110)) else { return }
            activeIndex = toIndex
            if passed {
                nodeScale = 0.82
                withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) {
                    nodeScale = 1.28
                }
                guard await pause(for: .milliseconds(190)) else { return }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                    nodeScale = 1
                }
            } else {
                withAnimation(.easeOut(duration: 0.12)) {
                    failureHaloOpacity = 1
                    failureHaloScale = 1
                }
                guard await pause(for: .milliseconds(120)) else { return }
                withAnimation(.easeIn(duration: 0.18)) {
                    failureHaloScale = 1.65
                    failureHaloOpacity = 0
                }
            }
        } else if passed {
            nodeScale = 0.82
            withAnimation(.spring(response: 0.32, dampingFraction: 0.56)) {
                nodeScale = 1.28
            }
            guard await pause(for: .milliseconds(190)) else { return }
            withAnimation(.spring(response: 0.26, dampingFraction: 0.76)) {
                nodeScale = 1
            }
        } else {
            withAnimation(.easeOut(duration: 0.09)) {
                shakeOffset = -7
                failureHaloOpacity = 1
                failureHaloScale = 1
            }
            guard await pause(for: .milliseconds(90)) else { return }
            withAnimation(.easeInOut(duration: 0.11)) {
                shakeOffset = 6
                failureHaloScale = 1.35
                failureHaloOpacity = 0.5
            }
            guard await pause(for: .milliseconds(110)) else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.68)) {
                shakeOffset = 0
                failureHaloScale = 1.65
                failureHaloOpacity = 0
            }
        }

        guard await pause(for: .milliseconds(320)) else { return }
        withAnimation(.easeIn(duration: 0.18)) {
            railOpacity = 0
        }
        guard await pause(for: .milliseconds(185)) else { return }
        onFinished()
    }

    private func pause(for duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}
