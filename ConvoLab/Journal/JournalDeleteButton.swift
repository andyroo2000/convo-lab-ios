import SwiftUI

struct JournalDeleteButton: View {
    let action: () -> Void

    var body: some View {
        Button("Delete entry", action: action)
            .buttonStyle(JournalDeleteButtonStyle())
            .accessibilityIdentifier("JournalDeleteEntry")
    }
}

private struct JournalDeleteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.red)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(.red.opacity(configuration.isPressed ? 0.08 : 0), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.red.opacity(0.25)))
    }
}
