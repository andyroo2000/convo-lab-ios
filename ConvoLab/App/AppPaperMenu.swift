import SwiftUI

struct AppPaperMenu<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            groups.fixedSize(horizontal: false, vertical: true)
            ScrollView { groups }.accessibilityIdentifier("AppPaperMenuScroll")
        }
        .frame(idealWidth: typeSize.isAccessibilitySize ? 350 : 260)
        .foregroundStyle(ConvoLabTheme.navy)
        .presentationCompactAdaptation(.popover)
        .presentationBackground(ConvoLabTheme.cream)
        .preferredColorScheme(.light)
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: 8) { content }.padding(14)
    }
}

struct AppPaperMenuGroup<Content: View>: View {
    let title: String
    @ScaledMetric(relativeTo: .caption2) private var headingSize = 10.0
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: headingSize, weight: .medium)).tracking(1.5)
                .foregroundStyle(ConvoLabTheme.navy.opacity(0.67)).padding(.horizontal, 12)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

struct AppPaperMenuRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let icon: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if !typeSize.isAccessibilitySize {
                    Image(systemName: icon).frame(width: 24)
                }
                Text(title).font(.custom("CrimsonPro-Regular", size: 20, relativeTo: .body))
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark") }
            }
            .padding(.horizontal, 12).frame(minHeight: 49)
            .background(selected ? Color(red: 0.906, green: 0.929, blue: 0.812) : .clear, in: .rect(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
