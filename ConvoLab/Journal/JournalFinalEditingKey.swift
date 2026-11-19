import SwiftUI

struct JournalFinalEditingKey: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() || value }
}
