import SwiftUI

enum JournalVersion: String, CaseIterable {
    case draft = "Draft"
    case final = "Final"
}

struct JournalVersionPicker: View {
    @Binding var selection: JournalVersion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(JournalVersion.allCases, id: \.self) { version in
                Button { selection = version } label: {
                    Text(version.rawValue).font(.subheadline.weight(.medium))
                        .foregroundStyle(selection == version ? Color(uiColor: JournalPopoverStyle.ink) : .secondary)
                        .frame(minWidth: 80, minHeight: 44)
                        .background(selection == version ? Color(.systemBackground) : .clear, in: Capsule())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selection == version ? .isSelected : [])
            }
        }.padding(4).background(Color(.secondarySystemBackground), in: Capsule())
            .accessibilityElement(children: .contain).accessibilityLabel("Entry version")
    }
}
