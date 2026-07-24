import SwiftUI

struct StudyPitchAccentDiagram: View {
    let pitchAccent: StudyCardPresentation.PitchAccent

    var body: some View {
        GeometryReader { proxy in
            let columnWidth = proxy.size.width / CGFloat(pitchAccent.morae.count)
            let points = pitchAccent.pattern.enumerated().map { index, value in
                CGPoint(
                    x: columnWidth * (CGFloat(index) + 0.5),
                    y: value == 1 ? 18 : 46
                )
            }

            Canvas { context, _ in
                for index in points.indices.dropLast() {
                    var line = Path()
                    line.move(to: points[index])
                    line.addLine(to: points[index + 1])
                    context.stroke(
                        line,
                        with: .color(ConvoLabTheme.navy),
                        style: .init(lineWidth: 3, lineCap: .round)
                    )
                }

                for (index, point) in points.enumerated() {
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: point.x - 4,
                            y: point.y - 4,
                            width: 8,
                            height: 8
                        )),
                        with: .color(ConvoLabTheme.navy)
                    )
                    context.draw(
                        Text(pitchAccent.morae[index])
                            .font(.caption.bold())
                            .foregroundStyle(ConvoLabTheme.navy),
                        at: CGPoint(x: point.x, y: 76)
                    )
                }
            }
        }
        .frame(
            maxWidth: min(CGFloat(pitchAccent.morae.count) * 42, 360),
            minHeight: 92,
            maxHeight: 92
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Pitch accent for \(pitchAccent.expression), \(pitchAccent.reading), \(pitchAccent.patternName)"
        )
    }
}
