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
        HStack(spacing: 5) {
            ForEach(JournalVersion.allCases, id: \.self) { version in
                Button { selection = version } label: {
                    Text(version.rawValue).font(.custom("CrimsonPro-Regular", size: 19, relativeTo: .body))
                        .padding(.horizontal, compact ? 10 : 16).frame(minWidth: compact ? 90 : nil, minHeight: 44)
                        .foregroundStyle(selection == version ? .white : Color(red: 0.278, green: 0.4, blue: 0.298))
                        .background(selection == version ? JournalDeskStyle.green : Color(red: 0.97, green: 0.98, blue: 0.95), in: Capsule())
                        .overlay(Capsule().stroke(Color(red: 0.70, green: 0.79, blue: 0.67)))
                }.buttonStyle(.plain).accessibilityAddTraits(selection == version ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("Entry version")
    }
}
