import SwiftUI

/// Keyed by mode so an inactive navigation stack cannot hide another mode's header.
struct AppSessionFocusKey: PreferenceKey {
    static var defaultValue: [AppMode: Bool] { [:] }

    static func reduce(value: inout [AppMode: Bool], nextValue: () -> [AppMode: Bool]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
