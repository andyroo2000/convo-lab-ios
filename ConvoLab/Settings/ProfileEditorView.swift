import SwiftUI

struct ProfileEditorView: View {
    let auth: AuthStore
    @State private var name: String
    @State private var email: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    init(auth: AuthStore, user: CurrentUser) {
        self.auth = auth
        _name = State(initialValue: user.name)
        _email = State(initialValue: user.email)
    }

    var body: some View {
        JournalSettingsPanel(title: "Edit profile") {
            fieldLayout {
                JournalSettingsField(title: "Name") {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                        .accessibilityLabel("Name")
                }
                JournalSettingsField(title: "Email") {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .accessibilityLabel("Email")
                }
            }
            .padding(.top, 8)
            JournalAuthError(message: auth.errorMessage).padding(.top, 12)
            HStack {
                Spacer()
                Button(auth.isWorking ? "Saving…" : "Save profile") {
                    Task {
                        if await auth.updateProfile(name: cleanName, email: cleanEmail) { dismiss() }
                    }
                }
                .buttonStyle(JournalSettingsSubmitStyle())
                .disabled(cleanName.isEmpty || cleanEmail.isEmpty || auth.isWorking)
                .accessibilityIdentifier("SettingsSaveProfile")
            }
            .padding(.top, 28)
        }
        .interactiveDismissDisabled(auth.isWorking)
    }

    private var fieldLayout: AnyLayout {
        sizeClass == .regular && !typeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 22))
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct PasswordEditorView: View {
    let auth: AuthStore
    @State private var currentPassword = ""
    @State private var password = ""
    @State private var confirmation = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        JournalSettingsPanel(title: "Change password") {
            VStack(alignment: .leading, spacing: 22) {
                JournalSettingsField(title: "Current password") {
                    SecureField("Current password", text: $currentPassword).textContentType(.password)
                }
                JournalSettingsField(title: "New password") {
                    SecureField("New password", text: $password).textContentType(.newPassword)
                }
                JournalSettingsField(title: "Confirm password") {
                    SecureField("Confirm password", text: $confirmation).textContentType(.newPassword)
                }
                JournalAuthError(message: auth.errorMessage)
            }
            .padding(.top, 8)
            HStack {
                Spacer()
                Button(auth.isWorking ? "Updating…" : "Update password", action: updatePassword)
                    .buttonStyle(JournalSettingsSubmitStyle())
                    .disabled(
                        currentPassword.isEmpty || password.isEmpty || password != confirmation
                            || auth.isWorking)
            }
            .padding(.top, 28)
        }
        .interactiveDismissDisabled(auth.isWorking)
    }

    private func updatePassword() {
        Task {
            if await auth.updatePassword(
                currentPassword: currentPassword, password: password,
                passwordConfirmation: confirmation)
            {
                dismiss()
            }
        }
    }
}
