import SwiftUI

struct LoginView: View {
    let auth: AuthStore
    let onLogin: () async -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var showingReset = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CONVOLAB")
                            .font(.caption.weight(.black))
                            .tracking(3)
                            .foregroundStyle(ConvoLabTheme.coral)
                        Text("Study without\nbreaking your flow.")
                            .font(.largeTitle.bold())
                            .foregroundStyle(ConvoLabTheme.navy)
                        Text("Your flashcards and downloaded audio stay with you, even when the network doesn’t.")
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 16) {
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .submitLabel(.next)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .onSubmit(signIn)
                    }
                    .textFieldStyle(.roundedBorder)

                    if let error = auth.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }

                    Button(action: signIn) {
                        HStack {
                            if auth.isWorking {
                                ProgressView()
                            }
                            Text("Sign In")
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ConvoLabTheme.navy)
                    .disabled(email.isEmpty || password.isEmpty || auth.isWorking)

                    Button("Forgot password?") {
                        showingReset = true
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(28)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .paperBackground()
            .sheet(isPresented: $showingReset) {
                PasswordResetView(auth: auth, initialEmail: email)
            }
        }
    }

    private func signIn() {
        Task {
            await auth.login(email: email, password: password)
            if case .signedIn = auth.state {
                await onLogin()
            }
        }
    }
}

private struct PasswordResetView: View {
    let auth: AuthStore
    @State var email: String
    @State private var sent = false
    @Environment(\.dismiss) private var dismiss

    init(auth: AuthStore, initialEmail: String) {
        self.auth = auth
        _email = State(initialValue: initialEmail)
    }

    var body: some View {
        NavigationStack {
            Form {
                if sent {
                    ContentUnavailableView(
                        "Check your email",
                        systemImage: "envelope.badge",
                        description: Text("If that account exists, learning-os sent reset instructions.")
                    )
                } else {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    Button("Send Reset Link") {
                        Task {
                            sent = await auth.requestPasswordReset(email: email)
                        }
                    }
                    .disabled(email.isEmpty || auth.isWorking)
                }
            }
            .navigationTitle("Reset Password")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

