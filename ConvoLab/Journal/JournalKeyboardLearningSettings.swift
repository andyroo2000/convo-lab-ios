import SwiftUI

struct JournalKeyboardLearningSettings: View {
    @State private var confirming = false
    @State private var clearing = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remembers the conversions you choose on this device.")
            Button("Reset learned conversions") { confirming = true }
                .disabled(clearing)
                .accessibilityIdentifier("JournalKeyboardResetLearning")
            if let message { Text(message).accessibilityIdentifier("JournalKeyboardLearningStatus") }
        }
        .font(.custom("CrimsonPro-Regular", size: 18, relativeTo: .body))
        .confirmationDialog("Reset learned conversions?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { reset() }
        } message: {
            Text("Your journal entries and keyboard choice will stay as they are.")
        }
    }

    private func reset() {
        clearing = true
        Task { @MainActor in
            defer { clearing = false }
            do {
                try await JournalCandidateRequests.resetLearning()
                message = "Learned conversions cleared."
            } catch { message = "Couldn’t reset learned conversions. Please try again." }
        }
    }
}
