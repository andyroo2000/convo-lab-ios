import SwiftUI

enum AppMode: String, CaseIterable, Hashable, Identifiable {
    case study = "Study"
    case dailyAudio = "Daily Audio"
    case cards = "Cards"
    case time = "Time"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .study: "rectangle.stack.fill"
        case .dailyAudio: "headphones"
        case .cards: "square.and.pencil"
        case .time: "clock.fill"
        case .settings: "gearshape.fill"
        }
    }

    static let practice: [Self] = [.study, .dailyAudio]
    static let manage: [Self] = [.cards, .time, .settings]
}

struct AppModePicker: View {
    @Binding var selection: AppMode

    var body: some View {
        HStack {
            Menu {
                Section("Practice") { destinations(AppMode.practice) }
                Section("Manage") { destinations(AppMode.manage) }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: selection.icon)
                    Text(selection.rawValue).fontWeight(.semibold)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Switch mode, \(selection.rawValue)")
            .accessibilityIdentifier("app-mode-picker")
            Spacer()
        }
        .padding(.horizontal, 20)
        .foregroundStyle(ConvoLabTheme.navy)
        .background(ConvoLabTheme.cream)
    }

    private func destinations(_ modes: [AppMode]) -> some View {
        ForEach(modes) { mode in
            Button {
                selection = mode
            } label: {
                Label(mode.rawValue, systemImage: mode == selection ? "checkmark" : mode.icon)
            }
            .accessibilityIdentifier("app-mode-\(mode)")
        }
    }
}
