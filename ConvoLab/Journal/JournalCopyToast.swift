import SwiftUI

/// Confirmation stays attached to the menu that performed the copy.
struct JournalCopyToast: View {
    var body: some View {
        Label("Text copied", systemImage: "checkmark")
            .font(.custom("CrimsonPro-Regular", size: 17, relativeTo: .body))
            .foregroundStyle(JournalDeskStyle.green)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(red: 1, green: 0.992, blue: 0.961), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(red: 0.78, green: 0.82, blue: 0.75)))
            .shadow(color: .black.opacity(0.10), radius: 5, y: 2)
            .fixedSize().allowsHitTesting(false)
            .accessibilityIdentifier("JournalCopyToast")
    }
}
