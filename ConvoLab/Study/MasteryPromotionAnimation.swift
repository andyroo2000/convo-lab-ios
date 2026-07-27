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
            let cloudCenterY = Self.cloudCenterY(
                safeAreaTop: geometry.safeAreaInsets.top
            )

            ZStack {
                ConvoLabTheme.cream
                    .ignoresSafeArea()

                cloud
                    .frame(
                        width: Self.cloudSize.width,
                        height: Self.cloudSize.height
                    )
                    .position(x: geometry.size.width / 2, y: cloudCenterY)
                    .opacity(cloudOpacity)

                Text(label)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(ConvoLabTheme.navy)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.42)
                    .frame(maxWidth: min(geometry.size.width * 0.82, 480))
                    .scaleEffect(itemScale)
                    .position(
                        x: geometry.size.width / 2,
                        y: itemY(
                            in: geometry.size.height,
                            cloudCenterY: cloudCenterY
                        )
                    )
                    .opacity(itemOpacity)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .ignoresSafeArea()
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
                .font(.system(.headline, design: .rounded, weight: .heavy))
                .tracking(1.5)
                .foregroundStyle(ConvoLabTheme.navy)
                .offset(y: 5)
                .accessibilityHidden(true)
        }
    }

    static let cloudSize = CGSize(width: 210, height: 112)

    static func cloudCenterY(safeAreaTop: CGFloat) -> CGFloat {
        max(126, safeAreaTop + cloudSize.height / 2 + 8)
    }

    private func itemY(in height: CGFloat, cloudCenterY: CGFloat) -> CGFloat {
        let start = max(220, height * 0.52)
        let pause = cloudCenterY + 72
        let absorbed = cloudCenterY + 7

        if itemPosition <= 1 {
            return start + (pause - start) * itemPosition
        }
        return pause + (absorbed - pause) * (itemPosition - 1)
    }

    @MainActor
    private func runAnimation() async {
        if reduceMotion {
            itemPosition = 1
            itemScale = 0.66
            withAnimation(.easeOut(duration: 0.1)) {
                cloudOpacity = 1
                itemOpacity = 1
            }
            guard await pause(for: .milliseconds(450)) else { return }
            guard await pause(for: .seconds(1)) else { return }
            withAnimation(.easeIn(duration: 0.125)) {
                cloudOpacity = 0
                itemOpacity = 0
            }
            guard await pause(for: .milliseconds(130)) else { return }
            onFinished()
            return
        }

        withAnimation(.easeOut(duration: 0.11)) {
            cloudOpacity = 1
            itemOpacity = 1
        }
        guard await pause(for: .milliseconds(85)) else { return }

        withAnimation(.easeInOut(duration: 0.29)) {
            itemPosition = 1
            itemScale = 0.66
        }
        guard await pause(for: .milliseconds(750)) else { return }

        withAnimation(.easeIn(duration: 0.1)) {
            itemPosition = 2
            itemScale = 0.04
            itemOpacity = 0
            cloudLineWidth = 6
        }
        guard await pause(for: .milliseconds(105)) else { return }

        withAnimation(.easeOut(duration: 0.11)) {
            cloudLineWidth = 2
        }
        guard await pause(for: .milliseconds(140)) else { return }
        guard await pause(for: .seconds(1)) else { return }

        withAnimation(.easeIn(duration: 0.14)) {
            cloudOpacity = 0
        }
        guard await pause(for: .milliseconds(145)) else { return }
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
