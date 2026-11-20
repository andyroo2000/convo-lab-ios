import SwiftUI

struct AccountRegistrationView: View {
    let auth: AuthStore
    let onRegistered: () async -> Void
    @State private var name = ""
    @State private var email: String
    @State private var password = ""
    @State private var confirmation = ""
    @State private var inviteCode = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(auth: AuthStore, initialEmail: String, onRegistered: @escaping () async -> Void) {
        self.auth = auth
        self.onRegistered = onRegistered
        _email = State(initialValue: initialEmail)
    }

    var body: some View {
        NavigationStack {
            JournalAuthScreen {
                JournalAuthHeading(title: "Create an account")
                JournalAuthField(title: "Name") {
                    TextField("Name", text: $name).textContentType(.name)
                }
                JournalAuthField(title: "Email") {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                }
                JournalAuthField(title: "Invite code") {
                    TextField("Invite code", text: $inviteCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                JournalAuthField(title: "Password") {
                    SecureField("At least 8 characters", text: $password).textContentType(.newPassword)
                        .accessibilityIdentifier("auth-register-password")
                }
                JournalAuthField(title: "Confirm password") {
                    SecureField("Confirm password", text: $confirmation).textContentType(.newPassword)
                }
                if !password.isEmpty && !hasMinimumPasswordLength {
                    JournalAuthError(message: "Use at least 8 characters for your password.")
                }
                if !confirmation.isEmpty && password != confirmation {
                    JournalAuthError(message: "Passwords do not match.")
                }
                JournalAuthError(message: errorMessage)
                Button("Create an account", action: register)
                    .buttonStyle(JournalAuthSubmitStyle())
                    .disabled(!canRegister)
                    .accessibilityIdentifier("auth-register-submit")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .toolbarBackground(JournalBrandStyle.green, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(.white)
        }
    }

    private var hasMinimumPasswordLength: Bool { password.unicodeScalars.count >= 8 }

    private var canRegister: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasMinimumPasswordLength && password == confirmation && !auth.isWorking && !isSubmitting
    }

    private func register() {
        guard canRegister else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            await auth.register(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                inviteCode: inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            errorMessage = auth.errorMessage
            if case .signedIn = auth.state {
                await onRegistered()
                dismiss()
            }
        }
    }
}
