import SwiftUI

struct AppModeToolbarAction: Identifiable, Equatable {
    let id: String
    let title: String
    var icon: String? = nil
    var isEnabled = true
    var isLoading = false
    let perform: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.icon == rhs.icon
            && lhs.isEnabled == rhs.isEnabled && lhs.isLoading == rhs.isLoading
    }
}

struct AppModeToolbar: Equatable {
    var buttons: [AppModeToolbarAction] = []
    var menu: [AppModeToolbarAction] = []
    var menuIdentifier = "AppModeMoreButton"
}

struct AppModeToolbarKey: PreferenceKey {
    static var defaultValue: [AppMode: AppModeToolbar] { [:] }

    static func reduce(value: inout [AppMode: AppModeToolbar], nextValue: () -> [AppMode: AppModeToolbar]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct AppModeToolbarView: View {
    let toolbar: AppModeToolbar

    var body: some View {
        HStack(spacing: 4) {
            ForEach(toolbar.buttons) { item in
                Button(action: item.perform) {
                    buttonLabel(item).frame(minWidth: 44, minHeight: 44)
                }
                .disabled(!item.isEnabled)
                .accessibilityLabel(item.title)
                .accessibilityIdentifier(item.id)
            }
            if !toolbar.menu.isEmpty {
                Menu {
                    ForEach(toolbar.menu) { item in
                        Button(item.title, action: item.perform)
                            .disabled(!item.isEnabled)
                            .accessibilityIdentifier(item.id)
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .accessibilityLabel("More actions")
                .accessibilityIdentifier(toolbar.menuIdentifier)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func buttonLabel(_ item: AppModeToolbarAction) -> some View {
        if item.isLoading {
            ProgressView().controlSize(.small)
        } else if let icon = item.icon {
            Image(systemName: icon)
        } else {
            Text(item.title)
        }
    }
}
