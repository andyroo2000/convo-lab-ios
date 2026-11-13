import SwiftUI

struct JournalSpeechBubble: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: 16)
        path.move(to: CGPoint(x: 1, y: 22))
        path.addLine(to: CGPoint(x: -9, y: 30))
        path.addLine(to: CGPoint(x: 1, y: 38))
        path.closeSubpath()
        return path
    }
}
