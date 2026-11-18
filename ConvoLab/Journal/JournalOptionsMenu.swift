import SwiftUI

private typealias JournalMenuAction = (@escaping () -> Void) -> Void
private extension EnvironmentValues {
    @Entry var journalMenuAction: JournalMenuAction?
}

struct JournalOptionsMenu<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var showing = false
    @State private var pending: (() -> Void)?

    var body: some View {
        Button { showing = true } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .accessibilityLabel("More journal options").tint(JournalDeskStyle.green)
            .popover(isPresented: $showing, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(8).frame(minWidth: 270, idealWidth: 300, maxWidth: 340)
                    .environment(\.journalMenuAction, { action in pending = action; showing = false })
                    .environment(\.colorScheme, .light)
                    .presentationBackground(Color(red: 1, green: 0.992, blue: 0.961))
                    .presentationCompactAdaptation(.popover)
                    .onDisappear {
                        let action = pending
                        pending = nil
                        action?()
                    }
            }
    }
}

struct JournalOptionButton: View {
    let title: String
    let icon: String
    var detail: String? = nil
    let action: () -> Void
    @Environment(\.journalMenuAction) private var perform
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button {
            if let perform { perform(action) } else { action() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(JournalToolbarButtonStyle.blue).frame(width: 23)
                Text(title)
                Spacer(minLength: 8)
                if let detail { Text(detail).font(.custom("CrimsonPro-Regular", size: 16, relativeTo: .body)).foregroundStyle(.secondary) }
            }.font(.custom("CrimsonPro-Regular", size: 20, relativeTo: .body))
                .foregroundStyle(Color(uiColor: JournalPopoverStyle.ink))
                .padding(.horizontal, 10).padding(.vertical, 8).frame(minHeight: 44)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).opacity(enabled ? 1 : 0.45)
    }
}
