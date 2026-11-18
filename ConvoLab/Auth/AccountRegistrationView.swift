import SwiftUI

struct AccountRegistrationView: View {
    let auth: AuthStore
    let onRegistered: () async -> Void
    @State private var name = ""
    @State private var email: String
    @State private var password = ""
    @State private var confirmation = ""
    @State private var inviteCode = ""
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
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                JournalAuthField(title: "Password") {
                    SecureField("Password", text: $password).textContentType(.newPassword)
                }
                JournalAuthField(title: "Confirm password") {
                    SecureField("Confirm password", text: $confirmation).textContentType(.newPassword)
                }
                JournalAuthError(message: auth.errorMessage)
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

    private var canRegister: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.isEmpty
            && !inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty && password == confirmation && !auth.isWorking
    }

    private func register() {
        Task {
            await auth.register(name: name, email: email, password: password, inviteCode: inviteCode)
            if case .signedIn = auth.state {
                await onRegistered()
                dismiss()
            }
        }
    }
}
