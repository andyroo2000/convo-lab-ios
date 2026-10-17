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
    var action: AppModeHeaderAction? = nil

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
            Spacer(minLength: 12)
            if let action {
                Button("End session", action: action.perform)
                    .frame(minHeight: 44)
                    .disabled(!action.isEnabled)
                    .accessibilityIdentifier("StudyEndSessionButton")
            }
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

struct AppModeHeaderAction: Equatable {
    let id: UUID
    let isEnabled: Bool
    let perform: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.isEnabled == rhs.isEnabled
    }
}

// Each mode has at most one active session publishing its header action.
struct AppModeActionKey: PreferenceKey {
    static var defaultValue: [AppMode: AppModeHeaderAction] { [:] }
    static func reduce(value: inout [AppMode: AppModeHeaderAction], nextValue: () -> [AppMode: AppModeHeaderAction]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct HasAppModeHeaderKey: EnvironmentKey {
    static let defaultValue = false
}

private struct AppModeDestinationKey: EnvironmentKey {
    static let defaultValue = AppMode.study
}

extension EnvironmentValues {
    var appModeDestination: AppMode {
        get { self[AppModeDestinationKey.self] }
        set { self[AppModeDestinationKey.self] = newValue }
    }

    var hasAppModeHeader: Bool {
        get { self[HasAppModeHeaderKey.self] }
        set { self[HasAppModeHeaderKey.self] = newValue }
    }
}

struct AppModeHeader: ViewModifier {
    @Binding var selection: AppMode
    @State private var actions: [AppMode: AppModeHeaderAction] = [:]

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            AppModePicker(selection: $selection, action: actions[selection])
            content
        }
        .environment(\.hasAppModeHeader, true)
        .onPreferenceChange(AppModeActionKey.self) { actions = $0 }
    }
}
