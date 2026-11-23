import SwiftUI

enum StudySpeakerRhythm {
    static let duration = 2.56

    static func waveCount(at elapsed: TimeInterval) -> Int {
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: duration)
        switch phase {
        case ..<0.8: return 0
        case ..<1.2: return 1
        case ..<1.6: return 2
        default: return 3
        }
    }
}

struct StudySpeakerIcon: View {
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var size = 44
    @State private var startedAt = Date.now

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: !playing || reduceMotion)) { context in
            let waves = playing && !reduceMotion
                ? StudySpeakerRhythm.waveCount(at: context.date.timeIntervalSince(startedAt)) : 3
            Canvas { canvas, bounds in
                let scale = bounds.width / 44
                canvas.scaleBy(x: scale, y: scale)
                canvas.fill(Self.cone, with: .foreground)
                for index in 0..<waves {
                    var path = Path()
                    path.addArc(center: CGPoint(x: 22.3, y: 22),
                                radius: 6 + Double(index) * 5.8,
                                startAngle: .degrees(-45), endAngle: .degrees(45), clockwise: false)
                    canvas.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onChange(of: playing) { _, active in
            if active { startedAt = .now }
        }
    }

    private static var cone: Path {
        Path { path in
            path.move(to: CGPoint(x: 19.3, y: 9.8))
            path.addQuadCurve(to: CGPoint(x: 17.3, y: 9), control: CGPoint(x: 19.3, y: 8.2))
            path.addLine(to: CGPoint(x: 11.7, y: 14.7))
            path.addLine(to: CGPoint(x: 6, y: 15.3))
            path.addQuadCurve(to: CGPoint(x: 4.3, y: 17), control: CGPoint(x: 4.3, y: 15.3))
            path.addLine(to: CGPoint(x: 4.3, y: 27))
            path.addQuadCurve(to: CGPoint(x: 6, y: 28.7), control: CGPoint(x: 4.3, y: 28.7))
            path.addLine(to: CGPoint(x: 11.7, y: 29.3))
            path.addLine(to: CGPoint(x: 17.3, y: 35))
            path.addQuadCurve(to: CGPoint(x: 19.3, y: 34.2), control: CGPoint(x: 19.3, y: 35.8))
            path.closeSubpath()
        }
    }
}
