import SwiftUI

struct JournalSettingsPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                JournalAuthHeading(title: title)
                Spacer(minLength: 16)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Color(red: 0.92, green: 0.94, blue: 0.89), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(title)")
                .accessibilityIdentifier("SettingsClose-\(title)")
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 30)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .frame(idealWidth: 640, maxWidth: .infinity, idealHeight: 680, maxHeight: .infinity)
        .background(Self.paper)
        .foregroundStyle(JournalBrandStyle.ink)
        .font(.custom("Inter-Regular", size: 14, relativeTo: .body))
        .tint(JournalBrandStyle.blue)
        .preferredColorScheme(.light)
    }

    private static var paper: Color { Color(red: 1, green: 253 / 255, blue: 247 / 255) }
}

struct JournalSettingsChapter<Content: View>: View {
    let title: String
    let icon: String
    @Binding var expanded: String?
    @ViewBuilder let content: Content

    init(
        _ title: String, icon: String, expanded: Binding<String?>, @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        _expanded = expanded
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                expanded = expanded == title ? nil : title
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: icon).foregroundStyle(JournalBrandStyle.spine).frame(width: 18)
                    Text(title).font(.custom("Nunito-ExtraBold", size: 18, relativeTo: .headline))
                    Spacer(minLength: 8)
                    Image(systemName: expanded == title ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 17)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded == title ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("SettingsChapter-\(title)")
            if expanded == title {
                VStack(alignment: .leading, spacing: 16) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 30)
                    .padding(.bottom, 20)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

struct JournalSettingsAccountActions: View {
    let name: String
    let onEditProfile: () -> Void
    let onChangePassword: () -> Void
    let onSignOut: () -> Void
    let onDeleteAccount: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "person.fill")
                    .frame(width: 40, height: 40)
                    .foregroundStyle(JournalBrandStyle.spine)
                    .background(JournalBrandStyle.yellow, in: Circle())
                    .accessibilityHidden(true)
                Text(name).font(.custom("Nunito-ExtraBold", size: 18, relativeTo: .headline))
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                action("Edit Profile", icon: "person", perform: onEditProfile)
                action("Change Password", icon: "lock", perform: onChangePassword)
                action(
                    "Sign Out", icon: "rectangle.portrait.and.arrow.right", destructive: true,
                    perform: onSignOut)
                action("Delete Account", icon: "trash", destructive: true, perform: onDeleteAccount)
            }
        }
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), alignment: .leading),
            count: sizeClass == .regular && !typeSize.isAccessibilitySize ? 2 : 1)
    }

    private func action(
        _ title: String, icon: String, destructive: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption2)
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(destructive ? Color.red : JournalBrandStyle.ink)
    }
}
