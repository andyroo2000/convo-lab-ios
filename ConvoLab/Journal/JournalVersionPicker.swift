import SwiftUI

enum JournalVersion: String, CaseIterable {
    case draft = "Draft"
    case final = "Final"

    static func preferenceKey(owner: String, entry: String) -> String {
        "journal.version.\(owner).\(entry.lowercased())"
    }

    var chapter: String { self == .draft ? "1" : "2" }
}

struct JournalVersionPicker: View {
    @Binding var selection: JournalVersion
    var compact = false
    @ScaledMetric(relativeTo: .body) private var ringSize: CGFloat = 26
    @ScaledMetric(relativeTo: .callout) private var labelSize: CGFloat = 16

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: compact ? 14 : 18) { choices() }.fixedSize()
            VStack(alignment: .leading, spacing: 8) { choices() }
        }.background(alignment: .bottom) { Rectangle().fill(Color(red: 0.89, green: 0.91, blue: 0.95)).frame(height: 1) }
            .accessibilityElement(children: .contain).accessibilityLabel("Entry version")
    }

    private func choices() -> some View {
        ForEach(JournalVersion.allCases, id: \.self) { version in
            Button { selection = version } label: {
                HStack(spacing: 9) {
                    chapter(version)
                    Text(version.rawValue).font(.system(size: labelSize, weight: .semibold)).fixedSize()
                }
                .foregroundStyle(selection == version ? Color(uiColor: JournalPopoverStyle.ink) : Color(red: 0.42, green: 0.45, blue: 0.50))
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 16)
                .frame(minHeight: 44)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selection == version ? JournalToolbarButtonStyle.blue : .clear).frame(height: 2)
                }
            }.buttonStyle(.plain)
                .accessibilityAddTraits(selection == version ? .isSelected : [])
        }
    }

    private func chapter(_ version: JournalVersion) -> some View {
        let selected = selection == version
        return Text(version.chapter).font(.custom("KleeOne-SemiBold", size: 19, relativeTo: .body))
            .frame(width: ringSize, height: ringSize)
            .foregroundStyle(selected ? Color(red: 0.19, green: 0.37, blue: 0.59) : .secondary)
            .background(.white, in: Ellipse())
            .overlay(Ellipse().stroke(selected ? JournalToolbarButtonStyle.blue : .secondary, lineWidth: 1))
            .overlay(Ellipse().stroke(selected ? JournalToolbarButtonStyle.blue : .clear, lineWidth: 1).padding(-4))
            .rotationEffect(.degrees(-3)).accessibilityHidden(true)
    }
}
