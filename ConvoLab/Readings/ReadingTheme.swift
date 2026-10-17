import SwiftUI

struct ReadingTheme: Identifiable {
    let id: String
    let name: String
    let isDark: Bool
    let colors: [String]
    var background: Color { Self.color(colors[0]) }
    var accent: Color { Self.color(colors[6]) }
    var foreground: Color { Self.color(colors[2]) }

    static func resolve(_ id: String, dark: Bool) -> Self {
        all.first { $0.id == id } ?? all[dark ? 4 : 0]
    }

    private static func color(_ hex: String) -> Color {
        let value = UInt(hex.dropFirst(), radix: 16) ?? 0
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }

    static let all: [Self] = [
        .init(id: "parchment", name: "Original parchment", isDark: false, colors: ["#f6edd9", "#fff7e6", "#2d251c", "#75634f", "#d6c7a9", "#ead5a1", "#80551c"]),
        .init(id: "cream", name: "Cream & navy", isDark: false, colors: ["#fbf5e0", "#fffaf0", "#143256", "#5d6a7d", "#d5cfbe", "#dce4f0", "#11335c"]),
        .init(id: "porcelain", name: "Porcelain & blue", isDark: false, colors: ["#fafbfe", "#ffffff", "#27354b", "#65728a", "#d9e0ed", "#e0eaff", "#365ea8"]),
        .init(id: "rose", name: "Rose paper", isDark: false, colors: ["#fff1ed", "#fffaf7", "#49312f", "#826763", "#e5ccc5", "#f1d6cd", "#9c4f45"]),
        .init(id: "cobalt", name: "Ink & cobalt", isDark: true, colors: ["#141923", "#222c3e", "#f0eee8", "#b0bdd3", "#394962", "#2b426a", "#a2c2ff"]),
        .init(id: "navy-cyan", name: "Navy & cyan", isDark: true, colors: ["#111e32", "#1c2c43", "#fbf5e0", "#b9c4d4", "#3a4c65", "#203d59", "#68d1ed"]),
        .init(id: "navy-gold", name: "Navy & gold", isDark: true, colors: ["#15233b", "#20314c", "#f6edd9", "#b9becb", "#3d4b65", "#484332", "#f0d787"]),
        .init(id: "sepia", name: "Dark parchment", isDark: true, colors: ["#251e19", "#342b23", "#f6edd9", "#c1ad97", "#584637", "#55422b", "#e9c874"]),
        .init(id: "graphite", name: "Graphite & silver", isDark: true, colors: ["#1d1d21", "#2b2b31", "#f0ece4", "#b8b5bc", "#49464f", "#43414a", "#e0dce5"]),
        .init(id: "plum", name: "Plum & gold", isDark: true, colors: ["#271d2b", "#382a3e", "#f6edd9", "#cbb5cd", "#59405e", "#564239", "#f0d787"]),
        .init(id: "coral", name: "Charcoal & coral", isDark: true, colors: ["#241e21", "#352a30", "#f8eee3", "#cbb7be", "#57434b", "#593838", "#f3b0a0"]),
        .init(id: "parchment", name: "Original parchment", isDark: false, colors: ["#f6edd9", "#fff7e6", "#2d251c", "#75634f", "#d6c7a9", "#ead5a1", "#80551c"]),
        .init(id: "cream", name: "Cream & navy", isDark: false, colors: ["#fbf5e0", "#fffaf0", "#143256", "#5d6a7d", "#d5cfbe", "#dce4f0", "#11335c"]),
        .init(id: "porcelain", name: "Porcelain & blue", isDark: false, colors: ["#fafbfe", "#ffffff", "#27354b", "#65728a", "#d9e0ed", "#e0eaff", "#365ea8"]),
        .init(id: "rose", name: "Rose paper", isDark: false, colors: ["#fff1ed", "#fffaf7", "#49312f", "#826763", "#e5ccc5", "#f1d6cd", "#9c4f45"]),
        .init(id: "cobalt", name: "Ink & cobalt", isDark: true, colors: ["#141923", "#222c3e", "#f0eee8", "#b0bdd3", "#394962", "#2b426a", "#a2c2ff"]),
        .init(id: "navy-cyan", name: "Navy & cyan", isDark: true, colors: ["#111e32", "#1c2c43", "#fbf5e0", "#b9c4d4", "#3a4c65", "#203d59", "#68d1ed"]),
        .init(id: "navy-gold", name: "Navy & gold", isDark: true, colors: ["#15233b", "#20314c", "#f6edd9", "#b9becb", "#3d4b65", "#484332", "#f0d787"]),
        .init(id: "sepia", name: "Dark parchment", isDark: true, colors: ["#251e19", "#342b23", "#f6edd9", "#c1ad97", "#584637", "#55422b", "#e9c874"]),
        .init(id: "graphite", name: "Graphite & silver", isDark: true, colors: ["#1d1d21", "#2b2b31", "#f0ece4", "#b8b5bc", "#49464f", "#43414a", "#e0dce5"]),
        .init(id: "plum", name: "Plum & gold", isDark: true, colors: ["#271d2b", "#382a3e", "#f6edd9", "#cbb5cd", "#59405e", "#564239", "#f0d787"]),
        .init(id: "coral", name: "Charcoal & coral", isDark: true, colors: ["#241e21", "#352a30", "#f8eee3", "#cbb7be", "#57434b", "#593838", "#f3b0a0"]),
        .init(id: "parchment", name: "Original parchment", isDark: false, colors: ["#f6edd9", "#fff7e6", "#2d251c", "#75634f", "#d6c7a9", "#ead5a1", "#80551c"]),
        .init(id: "cream", name: "Cream & navy", isDark: false, colors: ["#fbf5e0", "#fffaf0", "#143256", "#5d6a7d", "#d5cfbe", "#dce4f0", "#11335c"]),
        .init(id: "porcelain", name: "Porcelain & blue", isDark: false, colors: ["#fafbfe", "#ffffff", "#27354b", "#65728a", "#d9e0ed", "#e0eaff", "#365ea8"]),
        .init(id: "rose", name: "Rose paper", isDark: false, colors: ["#fff1ed", "#fffaf7", "#49312f", "#826763", "#e5ccc5", "#f1d6cd", "#9c4f45"]),
        .init(id: "cobalt", name: "Ink & cobalt", isDark: true, colors: ["#141923", "#222c3e", "#f0eee8", "#b0bdd3", "#394962", "#2b426a", "#a2c2ff"]),
        .init(id: "navy-cyan", name: "Navy & cyan", isDark: true, colors: ["#111e32", "#1c2c43", "#fbf5e0", "#b9c4d4", "#3a4c65", "#203d59", "#68d1ed"]),
        .init(id: "navy-gold", name: "Navy & gold", isDark: true, colors: ["#15233b", "#20314c", "#f6edd9", "#b9becb", "#3d4b65", "#484332", "#f0d787"]),
        .init(id: "sepia", name: "Dark parchment", isDark: true, colors: ["#251e19", "#342b23", "#f6edd9", "#c1ad97", "#584637", "#55422b", "#e9c874"]),
        .init(id: "graphite", name: "Graphite & silver", isDark: true, colors: ["#1d1d21", "#2b2b31", "#f0ece4", "#b8b5bc", "#49464f", "#43414a", "#e0dce5"]),
        .init(id: "plum", name: "Plum & gold", isDark: true, colors: ["#271d2b", "#382a3e", "#f6edd9", "#cbb5cd", "#59405e", "#564239", "#f0d787"]),
        .init(id: "coral", name: "Charcoal & coral", isDark: true, colors: ["#241e21", "#352a30", "#f8eee3", "#cbb7be", "#57434b", "#593838", "#f3b0a0"]),
    ]
}

enum ReadingFormat: String, CaseIterable, Identifiable {
    case reflow = "Phone reader"
    case original = "Book layout"
    case companion = "Paper companion"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .reflow: "text.alignleft"
        case .original: "book"
        case .companion: "list.bullet"
        }
    }
}
