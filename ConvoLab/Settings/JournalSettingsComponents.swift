import SwiftUI

struct JournalSettingsPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text(title)
                    .font(.custom("CrimsonPro-Regular", size: 34, relativeTo: .largeTitle))
                    .fontWeight(.medium)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 16)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 44, height: 44)
                        .background(Color(red: 0.92, green: 0.94, blue: 0.89), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(title)")
                .accessibilityIdentifier("SettingsClose-\(title)")
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)
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
        .foregroundStyle(ConvoLabTheme.navy)
        .font(.custom("CrimsonPro-Regular", size: 20, relativeTo: .body))
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
                    if title != "Account" {
                        Image(systemName: icon).foregroundStyle(JournalBrandStyle.spine).frame(width: 18)
                    }
                    Text(title)
                        .font(.custom("CrimsonPro-Regular", size: 23, relativeTo: .headline))
                        .fontWeight(.medium)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(.custom("Anton-Regular", fixedSize: 30))
                    .frame(width: 42, height: 42)
                    .foregroundStyle(ConvoLabTheme.navy)
                    .background(ConvoLabTheme.cream, in: Circle())
                    .padding(3)
                    .background(JournalBrandStyle.spine, in: Circle())
                    .accessibilityHidden(true)
                Text(name)
                    .font(.custom("CrimsonPro-Regular", size: 23, relativeTo: .headline))
                    .fontWeight(.medium)
            }
            VStack(alignment: .leading, spacing: 1) {
                action("Edit Profile", icon: "person", perform: onEditProfile)
                action("Change Password", icon: "lock", perform: onChangePassword)
                action(
                    "Sign Out", icon: "rectangle.portrait.and.arrow.right",
                    perform: onSignOut)
                action("Delete Account", icon: "trash", destructive: true, perform: onDeleteAccount)
            }
        }
    }

    private func action(
        _ title: String, icon: String, destructive: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 17)).frame(width: 18)
                Text(title)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption2)
            }
            .padding(.vertical, 8)
            .frame(minHeight: 45, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(destructive ? Color(red: 174 / 255, green: 81 / 255, blue: 63 / 255) : ConvoLabTheme.navy)
    }
}

struct JournalSettingsField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
            content
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(white: 0.82)))
        }
    }
}

struct JournalSettingsSubmitStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("CrimsonPro-Regular", size: 20, relativeTo: .body))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .foregroundStyle(ConvoLabTheme.navy)
            .background(Color(red: 0.92, green: 0.94, blue: 0.89), in: RoundedRectangle(cornerRadius: 9))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
    }
}
