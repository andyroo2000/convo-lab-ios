import SwiftUI

struct JournalHighlightLegend: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { items }
            VStack(alignment: .leading, spacing: 8) { items }
        }.font(.caption).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
    }

    private var items: some View {
        Group {
            item("Correction", fill: JournalPopoverStyle.correctionFill, line: JournalPopoverStyle.correctionLine, optional: false)
            item("Optional change", fill: JournalPopoverStyle.optionalFill, line: JournalPopoverStyle.optionalLine, optional: true)
        }
    }

    private func item(_ label: String, fill: UIColor, line: UIColor, optional: Bool) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3).fill(Color(uiColor: fill))
                .frame(width: 17, height: 12)
                .overlay(alignment: .bottom) {
                    UnevenRoundedRectangle().stroke(Color(uiColor: line), style: StrokeStyle(lineWidth: 1, dash: optional ? [3, 2] : []))
                        .frame(height: 1)
                }.accessibilityHidden(true)
            Text(label).fixedSize()
        }
    }
}
