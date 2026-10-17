import SwiftUI

enum AppMode: String, CaseIterable, Hashable, Identifiable {
    case study = "Study"
    case dailyAudio = "Daily Audio"
    case readings = "Readings"
    case cards = "Cards"
    case time = "Time"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .study: "rectangle.stack.fill"
        case .dailyAudio: "headphones"
        case .readings: "book.closed"
        case .cards: "square.and.pencil"
        case .time: "clock.fill"
        case .settings: "gearshape.fill"
        }
    }

    static let practice: [Self] = [.study, .dailyAudio, .readings]
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
            .accessibilityAddTraits(mode == selection ? .isSelected : [])
            .accessibilityIdentifier("app-mode-\(mode)")
        }
    }
}

struct AppModeActionKey: PreferenceKey {
    static var defaultValue: AnyView? { nil }
    static func reduce(value: inout AnyView?, nextValue: () -> AnyView?) {
        value = nextValue() ?? value
    }
}

private struct HasAppModeHeaderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var hasAppModeHeader: Bool {
        get { self[HasAppModeHeaderKey.self] }
        set { self[HasAppModeHeaderKey.self] = newValue }
    }
}

struct AppModeHeader: ViewModifier {
    @Binding var selection: AppMode

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            AppModePicker(selection: $selection)
            content
        }
        .environment(\.hasAppModeHeader, true)
        .overlayPreferenceValue(AppModeActionKey.self, alignment: .topTrailing) { action in
            action.padding(.trailing, 20)
        }
    }
}
