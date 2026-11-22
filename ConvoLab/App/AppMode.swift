import SwiftUI

enum AppMode: String, CaseIterable, Hashable, Identifiable {
    case study = "Study"
    case journal = "Journal"
    case readings = "Readings"
    case cards = "Cards"
    case time = "Time"
    case settings = "Settings"

    var id: String { rawValue }
    var headerTitle: String { self == .time ? "Study Time" : rawValue }
    var icon: String {
        switch self {
        case .study: "rectangle.stack.fill"
        case .journal: "book.pages"
        case .readings: "book.closed"
        case .cards: "square.and.pencil"
        case .time: "clock.fill"
        case .settings: "gearshape.fill"
        }
    }

    static let practice: [Self] = [.study, .journal, .readings]
    static let manage: [Self] = [.cards, .time]
}

struct AppModePicker: View {
    @Environment(\.availableAppModes) private var availableModes
    @Binding var selection: AppMode
    var action: AppModeHeaderAction? = nil
    var toolbar: AppModeToolbar = .init()
    @State private var showingDestinations = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var navigationModes: [AppMode] { availableModes.filter { $0 != .settings } }

    var body: some View {
        let stacksHeader = selection == .journal && dynamicTypeSize.isAccessibilitySize
        let layout = stacksHeader
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            if !dynamicTypeSize.isAccessibilitySize {
                Text("CONVO-LAB").font(.custom("Anton-Regular", fixedSize: 30))
                    .tracking(-0.5).foregroundStyle(JournalBrandStyle.yellow).fixedSize()
                    .accessibilityHidden(true)
                Rectangle().fill(.white.opacity(0.4)).frame(width: 1, height: 32)
                    .padding(.horizontal, 3).accessibilityHidden(true)
            }
            Button {
                if navigationModes.count > 1 { showingDestinations = true }
                else if let mode = navigationModes.first { selection = mode }
            } label: {
                HStack(spacing: 4) {
                    Text(selection.headerTitle).font(.custom("CrimsonPro-Regular", size: 18, relativeTo: .body)).fontWeight(.medium).lineLimit(1).minimumScaleFactor(0.85)
                    if navigationModes.count > 1 {
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(navigationModes.count > 1 ? "Switch mode, \(selection.headerTitle)" : selection.headerTitle)
            .accessibilityIdentifier("app-mode-picker")
            .disabled(toolbar.preventsNavigation || (navigationModes.count == 1 && navigationModes.first == selection))
            .popover(isPresented: $showingDestinations, arrowEdge: .top) {
                destinationPicker
            }
            if !stacksHeader { Spacer(minLength: 0) }
            if let action {
                Button("End session", action: action.perform)
                    .frame(minHeight: 44)
                    .disabled(!action.isEnabled)
                    .accessibilityIdentifier("StudyEndSessionButton")
            } else {
                HStack(spacing: 10) {
                    AppModeToolbarView(toolbar: selection == .journal ? AppModeToolbar(buttons: toolbar.buttons) : toolbar)
                        .fixedSize(horizontal: selection == .journal, vertical: false)
                    if stacksHeader { Spacer(minLength: 0) }
                    AppAccountMenu(selection: $selection, journalActions: toolbar.menu, preventsNavigation: toolbar.preventsNavigation)
                }
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
        AppPaperMenu {
            destinationGroup("Practice", modes: AppMode.practice)
            if AppMode.manage.contains(where: navigationModes.contains) {
                Divider().padding(.horizontal, 12)
                destinationGroup("Manage", modes: AppMode.manage)
            }
        }
    }

    @ViewBuilder private func destinationGroup(_ title: String, modes: [AppMode]) -> some View {
        let visible = modes.filter { availableModes.contains($0) }
        if !visible.isEmpty {
            AppPaperMenuGroup(title: title) {
                ForEach(visible) { mode in
                    AppPaperMenuRow(title: mode.rawValue, icon: mode.icon, selected: mode == selection) {
                        showingDestinations = false
                        selection = mode
                    }
                    .accessibilityIdentifier("app-mode-\(mode)")
                }
            }
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
