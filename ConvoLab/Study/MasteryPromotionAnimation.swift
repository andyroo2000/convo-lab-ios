import SwiftUI
import UIKit

struct MasteryPromotionAnimation: View {
    let label: String
    let level: String
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var cloudOpacity = 0.0
    @State private var cloudLineWidth = 2.0
    @State private var itemOpacity = 0.0
    @State private var itemScale = 1.0
    @State private var itemPosition = 0.0

    private var announcement: String {
        "\(label) reached \(level.capitalized)"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                cloud
                    .frame(width: 154, height: 96)
                    .position(x: geometry.size.width / 2, y: 65)
                    .opacity(cloudOpacity)

                Text(label)
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                    .foregroundStyle(ConvoLabTheme.navy)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.42)
                    .frame(maxWidth: min(geometry.size.width * 0.82, 480))
                    .scaleEffect(itemScale)
                    .position(
                        x: geometry.size.width / 2,
                        y: itemY(in: geometry.size.height)
                    )
                    .opacity(itemOpacity)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(announcement)
        .task(id: "\(label)|\(level)") {
            UIAccessibility.post(notification: .announcement, argument: announcement)
            await runAnimation()
        }
    }

    private var cloud: some View {
        ZStack {
            MasteryCloudShape()
                .fill(.white)
                .shadow(color: ConvoLabTheme.navy.opacity(0.12), radius: 8, y: 3)

            MasteryCloudShape()
                .stroke(
                    ConvoLabTheme.navy,
                    style: StrokeStyle(lineWidth: cloudLineWidth, lineJoin: .round)
                )

            Text(level.uppercased())
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(ConvoLabTheme.navy)
                .offset(y: 5)
                .accessibilityHidden(true)
        }
    }

    private func itemY(in height: CGFloat) -> CGFloat {
        let start = max(220, height * 0.52)
        let pause = CGFloat(137)
        let absorbed = CGFloat(72)

        if itemPosition <= 1 {
            return start + (pause - start) * itemPosition
        }
        return pause + (absorbed - pause) * (itemPosition - 1)
    }

    @MainActor
    private func runAnimation() async {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) {
                cloudOpacity = 1
            }
            guard await pause(for: .milliseconds(900)) else { return }
            withAnimation(.easeIn(duration: 0.25)) {
                cloudOpacity = 0
            }
            guard await pause(for: .milliseconds(260)) else { return }
            onFinished()
            return
        }

        withAnimation(.easeOut(duration: 0.22)) {
            cloudOpacity = 1
            itemOpacity = 1
        }
        guard await pause(for: .milliseconds(170)) else { return }

        withAnimation(.easeInOut(duration: 0.58)) {
            itemPosition = 1
            itemScale = 0.66
        }
        guard await pause(for: .milliseconds(1_500)) else { return }

        withAnimation(.easeIn(duration: 0.2)) {
            itemPosition = 2
            itemScale = 0.04
            itemOpacity = 0
            cloudLineWidth = 6
        }
        guard await pause(for: .milliseconds(210)) else { return }

        withAnimation(.easeOut(duration: 0.22)) {
            cloudLineWidth = 2
        }
        guard await pause(for: .milliseconds(280)) else { return }

        withAnimation(.easeIn(duration: 0.28)) {
            cloudOpacity = 0
        }
        guard await pause(for: .milliseconds(290)) else { return }
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

private struct MasteryCloudShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * x / 190,
                y: rect.minY + rect.height * y / 118
            )
        }

        var path = Path()
        path.move(to: point(43, 99))
        path.addCurve(
            to: point(12, 67),
            control1: point(20, 99),
            control2: point(8, 85)
        )
        path.addCurve(
            to: point(45, 43),
            control1: point(15, 51),
            control2: point(29, 42)
        )
        path.addCurve(
            to: point(87, 16),
            control1: point(50, 24),
            control2: point(67, 12)
        )
        path.addCurve(
            to: point(137, 27),
            control1: point(102, 2),
            control2: point(128, 7)
        )
        path.addCurve(
            to: point(178, 62),
            control1: point(159, 27),
            control2: point(176, 42)
        )
        path.addCurve(
            to: point(143, 99),
            control1: point(181, 84),
            control2: point(164, 99)
        )
        path.closeSubpath()
        return path
    }
}
