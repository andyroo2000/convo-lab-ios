import SwiftUI

struct LoginView: View {
    let auth: AuthStore
    let onLogin: () async -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showingReset = false
    @State private var showingRegistration = false
    @FocusState private var focus: Field?
    private enum Field { case email, password }

    init(auth: AuthStore, onLogin: @escaping () async -> Void) {
        self.auth = auth
        self.onLogin = onLogin
        _errorMessage = State(initialValue: auth.errorMessage)
    }

    var body: some View {
        NavigationStack {
            JournalAuthScreen {
                JournalAuthHeading(title: "Sign in")
                HStack(spacing: 4) {
                    Text("New user?").foregroundStyle(Color(white: 0.34))
                    Button("Create an account") { showingRegistration = true }
                        .underline()
                        .foregroundStyle(JournalBrandStyle.blue)
                        .frame(minHeight: 44)
                }
                .font(.custom("Inter-Regular", size: 12, relativeTo: .caption))
                JournalAuthField(title: "Email") {
                    TextField("Enter your email", text: $email)
                        .accessibilityLabel("Email")
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .submitLabel(.next)
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }
                }
                JournalAuthField(title: "Password", onReset: { showingReset = true }) {
                    SecureField("Enter your password", text: $password)
                        .accessibilityLabel("Password")
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focus, equals: .password)
                        .onSubmit(signIn)
                }
                JournalAuthError(message: errorMessage)
                HStack {
                    Spacer()
                    Button(action: signIn) {
                        HStack {
                            if auth.isWorking { ProgressView().tint(.white) }
                            Text("Sign in")
                        }
                    }
                    .buttonStyle(JournalAuthSubmitStyle())
                    .disabled(cleanEmail.isEmpty || password.isEmpty || auth.isWorking || isSubmitting)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: showingReset) { _, _ in errorMessage = nil }
            .onChange(of: showingRegistration) { _, _ in errorMessage = nil }
            .outsideDismissibleSheet(isPresented: $showingReset) {
                PasswordResetView(auth: auth, initialEmail: email)
            }
            .outsideDismissibleSheet(isPresented: $showingRegistration) {
                AccountRegistrationView(auth: auth, initialEmail: email, onRegistered: onLogin)
            }
        }
    }

    private var cleanEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func signIn() {
        guard !cleanEmail.isEmpty, !password.isEmpty, !auth.isWorking, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        focus = nil
        Task {
            defer { isSubmitting = false }
            await auth.login(email: cleanEmail, password: password)
            errorMessage = auth.errorMessage
            if case .signedIn = auth.state { await onLogin() }
        }
    }
}
