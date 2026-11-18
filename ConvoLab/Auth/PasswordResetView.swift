import SwiftUI

struct PasswordResetView: View {
    let auth: AuthStore
    @State private var email: String
    @State private var sent = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
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
                    JournalAuthError(message: errorMessage)
                    Button("Send reset link", action: sendResetLink)
                    .buttonStyle(JournalAuthSubmitStyle())
                    .disabled(cleanEmail.isEmpty || auth.isWorking || isSubmitting)
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

    private var cleanEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func sendResetLink() {
        guard !cleanEmail.isEmpty, !auth.isWorking, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            sent = await auth.requestPasswordReset(email: cleanEmail)
            errorMessage = auth.errorMessage
        }
    }
}
