import SwiftUI

enum StudyTimeTab: String, CaseIterable {
    case rhythm = "Rhythm", recap = "Recap", mastery = "Mastery", entries = "Entries"
}

enum StudyTimePaper {
    static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(rgb >> 16) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }

    static let desk = color(0xf8f7f1, 0x18221c)
    static let paper = color(0xfffdf4, 0x223027)
    static let ink = color(0x173b35, 0xf6f4e7)
    static let green = color(0x316641, 0x386d49)
    static let sage = color(0xe8eadb, 0x324337)
    static func type(_ size: CGFloat, _ style: Font.TextStyle = .body) -> Font {
        .custom("CrimsonPro-Regular", size: size, relativeTo: style)
    }
}

struct StudyTimeRecordHeader: View {
    let add: () -> Void

    var body: some View {
        HStack {
            Text("Study Time").font(StudyTimePaper.type(36, .largeTitle)).accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: add) {
                Label("Log time", systemImage: "plus").font(StudyTimePaper.type(19))
                    .padding(.horizontal, 14).frame(minHeight: 44)
                    .foregroundStyle(.white).background(StudyTimePaper.green, in: Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier("ManualStudyTimeAddButton")
        }
    }
}

struct StudyTimeRangePicker: View {
    @Binding var selection: StudyTimeRange

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StudyTimeRange.allCases) { range in
                Button {
                    selection = range
                } label: {
                    Text(range.title).font(StudyTimePaper.type(17))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(selection == range ? .white : StudyTimePaper.ink)
                        .background(selection == range ? StudyTimePaper.green : .clear, in: Capsule())
                }.buttonStyle(.plain)
                .accessibilityAddTraits(selection == range ? .isSelected : [])
            }
        }.padding(3).background(StudyTimePaper.sage, in: Capsule())
        .accessibilityElement(children: .contain).accessibilityLabel("Time span")
    }
}

struct StudyTimeRecordTabs: View {
    @Binding var selected: StudyTimeTab

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(StudyTimeTab.allCases.enumerated()), id: \.element) { index, tab in
                Button {
                    selected = tab
                } label: {
                    Text(tab.rawValue).font(StudyTimePaper.type(18)).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(selected == tab ? .white : StudyTimePaper.ink)
                        .background(selected == tab ? StudyTimePaper.green : StudyTimePaper.sage,
                                    in: UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
                }.buttonStyle(.plain)
                .accessibilityValue("\(index + 1) of \(StudyTimeTab.allCases.count)")
                .accessibilityAddTraits(selected == tab ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("Study Time sections")
    }
}
