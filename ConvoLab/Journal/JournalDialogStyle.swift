import SwiftUI

enum JournalDialogStyle {
    static let paper = Color(red: 1, green: 253 / 255, blue: 247 / 255)
    static let ink = Color(uiColor: JournalPopoverStyle.ink)
    static let green = Color(red: 64 / 255, green: 124 / 255, blue: 53 / 255)
    static let sage = Color(red: 237 / 255, green: 243 / 255, blue: 230 / 255)
    static let border = Color(red: 213 / 255, green: 220 / 255, blue: 203 / 255)
    static let destructive = Color(red: 158 / 255, green: 68 / 255, blue: 61 / 255)
    static let body = Font.custom("CrimsonPro-Regular", size: 20, relativeTo: .body)
    static let heading = Font.custom("CrimsonPro-Regular", size: 30, relativeTo: .title2).weight(.medium)
}

/// Measure the content rather than expanding a small picker to a full-height sheet.
/// ScrollView keeps controls reachable when Dynamic Type exceeds the available height.
struct JournalDialogSheet<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 320

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .font(JournalDialogStyle.body)
        .foregroundStyle(JournalDialogStyle.ink)
        .tint(JournalDialogStyle.green)
        .background(JournalDialogStyle.paper)
        .overlay(alignment: .top) { JournalDeskStyle.green.frame(height: 4) }
        .presentationDetents([.height(max(200, ceil(contentHeight)))])
        .presentationCornerRadius(20)
        .presentationBackground(JournalDialogStyle.paper)
        .environment(\.colorScheme, .light)
    }
}

struct JournalDialogHeading: View {
    let title: String
    let closeLabel: String
    let close: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).font(JournalDialogStyle.heading).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            JournalDialogCloseButton(label: closeLabel, action: close)
        }
    }
}

struct JournalDialogCloseButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 16))
                .frame(width: 44, height: 44)
                .foregroundStyle(JournalDialogStyle.green)
                .background(JournalDialogStyle.sage, in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

struct JournalAvatarChoice: View {
    let url: String?
    let selected: Bool

    var body: some View {
        JournalAvatar(url: url).frame(width: 80, height: 80).padding(8)
            .background(.white, in: Circle()).clipShape(Circle())
            .frame(maxWidth: .infinity).padding(.vertical, 20)
            .background(selected ? JournalDialogStyle.sage : JournalDialogStyle.paper, in: .rect(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(selected ? JournalDialogStyle.green : JournalDialogStyle.border, lineWidth: selected ? 2 : 1) }
            .overlay(alignment: .topTrailing) {
                if selected { Image(systemName: "checkmark").font(.system(size: 14)).foregroundStyle(JournalDialogStyle.green).padding(10) }
            }.accessibilityHidden(true)
    }
}

struct JournalDialogCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(20)
            .background(JournalDialogStyle.paper)
            .overlay(alignment: .top) { JournalDeskStyle.green.frame(height: 4) }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(JournalDialogStyle.border) }
            .font(JournalDialogStyle.body).foregroundStyle(JournalDialogStyle.ink)
            .environment(\.colorScheme, .light)
    }
}
