import SwiftUI

struct PasswordResetView: View {
    let auth: AuthStore
    @State private var email: String
    @State private var sent = false
    @Environment(\.dismiss) private var dismiss

    init(auth: AuthStore, initialEmail: String) {
        self.auth = auth
        _email = State(initialValue: initialEmail)
    }

    var body: some View {
        NavigationStack {
            JournalAuthScreen {
                JournalAuthHeading(title: sent ? "Check your email" : "Reset password")
                if sent {
                    Text("If that account exists, we sent password reset instructions.")
                } else {
                    Text("Enter your email address and we’ll send you a link to reset your password.")
                        .foregroundStyle(Color(white: 0.34))
                    JournalAuthField(title: "Email") {
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                    }
                    JournalAuthError(message: auth.errorMessage)
                    Button("Send reset link") {
                        Task { sent = await auth.requestPasswordReset(email: email) }
                    }
                    .buttonStyle(JournalAuthSubmitStyle())
                    .disabled(email.isEmpty || auth.isWorking)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .toolbarBackground(JournalBrandStyle.green, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(.white)
        }
    }
}
