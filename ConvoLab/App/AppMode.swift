import SwiftUI

enum AppMode: String, CaseIterable, Hashable, Identifiable {
    case study = "Study"
    case dailyAudio = "Daily Audio"
    case journal = "Journal"
    case readings = "Readings"
    case cards = "Cards"
    case time = "Time"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .study: "rectangle.stack.fill"
        case .dailyAudio: "headphones"
        case .journal: "book.pages"
        case .readings: "book.closed"
        case .cards: "square.and.pencil"
        case .time: "clock.fill"
        case .settings: "gearshape.fill"
        }
    }

    static let practice: [Self] = [.study, .dailyAudio, .journal, .readings]
    static let manage: [Self] = [.cards, .time, .settings]
}

struct AppModePicker: View {
    @Environment(\.availableAppModes) private var availableModes
    @Binding var selection: AppMode
    var action: AppModeHeaderAction? = nil
    var toolbar: AppModeToolbar = .init()
    @State private var showingDestinations = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 6) {
            if !dynamicTypeSize.isAccessibilitySize {
                Text("CONVO-LAB").font(.custom("Anton-Regular", fixedSize: 30))
                    .tracking(-0.5).foregroundStyle(JournalBrandStyle.yellow).fixedSize()
                    .accessibilityHidden(true)
            }
            Button { showingDestinations = true } label: {
                HStack(spacing: 4) {
                    Text(selection.rawValue).font(.custom("CrimsonPro-Regular", size: 18, relativeTo: .body)).fontWeight(.medium).lineLimit(1).minimumScaleFactor(0.85)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch mode, \(selection.rawValue)")
            .accessibilityIdentifier("app-mode-picker")
            .disabled(toolbar.preventsNavigation)
            .popover(isPresented: $showingDestinations, arrowEdge: .top) {
                destinationPicker
                    .presentationCompactAdaptation(.popover)
                    .presentationBackground(ConvoLabTheme.cream)
                    .preferredColorScheme(.light)
            }
            Spacer(minLength: 0)
            if let action {
                Button("End session", action: action.perform)
                    .frame(minHeight: 44)
                    .disabled(!action.isEnabled)
                    .accessibilityIdentifier("StudyEndSessionButton")
            } else {
                AppModeToolbarView(toolbar: selection == .journal ? AppModeToolbar(buttons: toolbar.buttons) : toolbar)
                AppAccountMenu(selection: $selection, journalActions: toolbar.menu, preventsNavigation: toolbar.preventsNavigation)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(minHeight: 72)
        .foregroundStyle(.white)
        .background(JournalBrandStyle.green)
        .overlay(alignment: .leading) { JournalBrandStyle.spine.frame(width: 7) }
        .environment(\.colorScheme, .light)
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            destinationGroup("Practice", modes: AppMode.practice)
            Divider().padding(.horizontal, 12)
            destinationGroup("Manage", modes: AppMode.manage)
        }
        .padding(10)
        .frame(minWidth: 240)
        .foregroundStyle(ConvoLabTheme.navy)
        .background(ConvoLabTheme.cream)
    }

    private func destinationGroup(_ title: String, modes: [AppMode]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            destinations(modes)
        }
    }

    private func destinations(_ modes: [AppMode]) -> some View {
        ForEach(modes.filter { availableModes.contains($0) }) { mode in
            Button {
                showingDestinations = false
                selection = mode
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: mode.icon).frame(width: 24)
                    Text(mode.rawValue)
                    Spacer(minLength: 12)
                    if mode == selection { Image(systemName: "checkmark") }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(mode.rawValue)
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
    @State private var toolbars: [AppMode: AppModeToolbar] = [:]

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            AppModePicker(selection: $selection, action: actions[selection], toolbar: toolbars[selection] ?? .init())
            content
        }
        .environment(\.hasAppModeHeader, true)
        .onPreferenceChange(AppModeActionKey.self) { actions = $0 }
        .onPreferenceChange(AppModeToolbarKey.self) { toolbars = $0 }
    }
}
