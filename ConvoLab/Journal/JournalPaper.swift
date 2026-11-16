import SwiftUI

struct JournalPaper<Content: View>: View {
    var draft: JournalDraft?
    var reply = false
    var writing = false
    @ViewBuilder let content: () -> Content
    @Environment(\.journalTypography) private var typography
    @ScaledMetric(relativeTo: .body) private var scale = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !reply, let draft, !writing || !(draft.title ?? "").isEmpty {
                JournalPaperHeading(draft: draft, writing: writing)
            }
            content().environment(\.journalOnPaper, true)
                .background(alignment: .topLeading) {
                    JournalPaperRules(spacing: typography.size * scale * JournalPaperText.linePitch)
                        .stroke(Color(red: 0.77, green: 0.81, blue: 0.81), lineWidth: 0.5)
                        .accessibilityHidden(true)
                }
        }
        .padding(.top, reply ? 24 : 20).padding(.bottom, 36)
        .padding(.leading, 28).padding(.trailing, 14)
        .background {
            JournalPaperEdge(tornTop: reply)
                .fill(Color(red: 1, green: 0.992, blue: 0.961))
                .overlay {
                    Rectangle().fill(Color(red: 0.85, green: 0.58, blue: 0.53))
                        .frame(width: 1).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14)
                        .clipShape(JournalPaperEdge(tornTop: reply))
                }
                .overlay(JournalPaperEdge(tornTop: reply).stroke(Color(red: 0.90, green: 0.87, blue: 0.80), lineWidth: 0.6))
                .shadow(color: .black.opacity(0.08), radius: 2, y: 3)
                .accessibilityHidden(true)
        }
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(reply ? "Your reply" : "Journal entry")
    }
}

private struct JournalPaperHeading: View {
    let draft: JournalDraft
    let writing: Bool
    @Environment(\.journalTypography) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !writing {
                Text(JournalDates.notebook(draft.entryDate))
                .font(.custom("KleeOne-SemiBold", size: 17, relativeTo: .body))
                .foregroundStyle(Color(uiColor: JournalPopoverStyle.ink))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("JournalEntryDate")
            }
            Text(draft.title ?? "Untitled entry")
                .font(JournalTypography(font: typography.selection, size: 27).font)
                .foregroundStyle(Color(uiColor: JournalPopoverStyle.ink))
                .accessibilityAddTraits(.isHeader)
        }
    }
}

struct JournalPaperEdge: Shape {
    var tornTop: Bool
    // Stable, shallow variations keep a soft tear at any sheet width.
    private let depths: [CGFloat] = [5, 3, 6, 2, 4, 1, 5, 3, 6, 2, 4, 0, 3, 1, 5, 3, 6, 2, 4, 1, 3]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + (tornTop ? depths[0] : 0)))
        for index in 1..<depths.count {
            path.addLine(to: CGPoint(x: rect.minX + rect.width * CGFloat(index) / CGFloat(depths.count - 1),
                                    y: rect.minY + (tornTop ? depths[index] : 0)))
        }
        for index in depths.indices.reversed() {
            path.addLine(to: CGPoint(x: rect.minX + rect.width * CGFloat(index) / CGFloat(depths.count - 1),
                                    y: rect.maxY - depths[index] - 2))
        }
        path.closeSubpath()
        return path
    }
}

private struct JournalPaperRules: Shape {
    let spacing: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for y in stride(from: spacing, through: rect.height, by: spacing) {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + y))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + y))
        }
        return path
    }
}
