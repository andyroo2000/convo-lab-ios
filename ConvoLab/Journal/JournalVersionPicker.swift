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

    var body: some View {
        HStack(spacing: 2) {
            ForEach(JournalVersion.allCases, id: \.self) { version in
                Button { selection = version } label: {
                    HStack(spacing: 6) {
                        Text(version.chapter).font(.custom("KleeOne-SemiBold", size: 24, relativeTo: .title2)).accessibilityHidden(true)
                        Text(version.rawValue).font(.custom("KleeOne-SemiBold", size: 17, relativeTo: .body))
                    }
                        .foregroundStyle(selection == version ? Color(uiColor: JournalPopoverStyle.ink) : .secondary)
                        .frame(minWidth: compact ? 52 : 80, minHeight: 44)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(selection == version ? JournalToolbarButtonStyle.blue : .clear).frame(height: 2)
                        }
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selection == version ? .isSelected : [])
            }
        }.padding(4)
            .accessibilityElement(children: .contain).accessibilityLabel("Entry version")
    }
}
