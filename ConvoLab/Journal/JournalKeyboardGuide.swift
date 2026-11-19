import SwiftUI

struct JournalKeyboardGuide: View {
    @Environment(\.appAccountName) private var name

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Here’s where to change it later")
                .font(.custom("CrimsonPro-Regular", size: 19, relativeTo: .body))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { first; second }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 16) { first; second }
            }
        }.font(.custom("CrimsonPro-Regular", size: 17, relativeTo: .body))
            .foregroundStyle(Color(red: 0.30, green: 0.42, blue: 0.29))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("To change your keyboard later, open your account avatar in the top bar, then tap Keyboard under Journal.")
    }

    private var first: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Open your account", systemImage: "1.circle")
            VStack(spacing: 12) {
                HStack {
                    Text("Journal")
                    Spacer()
                    Text(name.first.map { String($0).uppercased() } ?? "?")
                        .font(.custom("Anton-Regular", fixedSize: 18)).frame(width: 30, height: 30)
                        .background(ConvoLabTheme.cream, in: Circle())
                        .overlay(Circle().stroke(JournalBrandStyle.spine, lineWidth: 3))
                }
                JournalDeskStyle.green.frame(height: 3)
                Rectangle().fill(.gray.opacity(0.2)).frame(height: 1)
            }.padding(10).frame(width: 148, height: 92)
                .background(.white.opacity(0.6), in: .rect(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.gray.opacity(0.2)))
        }
    }

    private var second: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Tap Keyboard", systemImage: "2.circle")
            VStack(alignment: .leading, spacing: 8) {
                Label("Appearance", systemImage: "textformat").foregroundStyle(.secondary)
                Label("Keyboard", systemImage: "keyboard").padding(5)
                    .background(Color(red: 0.929, green: 0.953, blue: 0.91), in: .rect(cornerRadius: 5))
            }.padding(8).frame(width: 148, height: 92)
                .background(.white.opacity(0.6), in: .rect(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.gray.opacity(0.2)))
        }
    }
}
