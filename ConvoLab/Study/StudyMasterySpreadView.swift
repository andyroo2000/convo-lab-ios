import SwiftUI

nonisolated struct StudyMasterySpreadEntry: Equatable, Identifiable, Sendable {
    let level: StudyMasteryLevel
    let count: Int
    let share: Double

    var id: StudyMasteryLevel { level }
    var title: String { level.rawValue.capitalized }
    var percentage: Int { Int((share * 100).rounded()) }
}

nonisolated extension StudyMasterySpread {
    var total: Int {
        max(0, apprentice)
            + max(0, guru)
            + max(0, master)
            + max(0, enlightened)
            + max(0, burned)
    }

    var entries: [StudyMasterySpreadEntry] {
        let counts: [StudyMasteryLevel: Int] = [
            .apprentice: max(0, apprentice),
            .guru: max(0, guru),
            .master: max(0, master),
            .enlightened: max(0, enlightened),
            .burned: max(0, burned),
        ]
        let total = total

        return StudyMasteryLevel.allCases.map { level in
            let count = counts[level] ?? 0
            return StudyMasterySpreadEntry(
                level: level,
                count: count,
                share: total > 0 ? Double(count) / Double(total) : 0
            )
        }
    }
}

struct StudyMasterySpreadView: View {
    let spread: StudyMasterySpread

    private var entries: [StudyMasterySpreadEntry] { spread.entries }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Item Spread")
                    .font(.headline)
                Spacer()
                Text("\(spread.total) cards")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            distributionBar
            details
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.72), in: .rect(cornerRadius: 18))
    }

    private var distributionBar: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(entries) { entry in
                    ZStack {
                        color(for: entry.level)
                        if entry.percentage >= 12 {
                            Text("\(entry.percentage)%")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .frame(width: proxy.size.width * entry.share)
                }
            }
        }
        .frame(height: 30)
        .background(ConvoLabTheme.navy.opacity(0.1))
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Item spread")
        .accessibilityValue(
            entries
                .map { "\($0.title) \($0.percentage) percent" }
                .joined(separator: ", ")
        )
    }

    private var details: some View {
        VStack(spacing: 0) {
            detailHeader
            ForEach(entries) { entry in
                Divider()
                HStack(spacing: 12) {
                    Label {
                        Text(entry.title)
                            .fontWeight(.semibold)
                    } icon: {
                        Circle()
                            .fill(color(for: entry.level))
                            .frame(width: 8, height: 8)
                    }
                    Spacer(minLength: 8)
                    Text(entry.count, format: .number)
                        .frame(width: 54, alignment: .trailing)
                        .monospacedDigit()
                    Text("\(entry.percentage)%")
                        .frame(width: 52, alignment: .trailing)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.subheadline)
                .frame(minHeight: 38)
            }
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            Text("Stage")
            Spacer(minLength: 8)
            Text("Cards")
                .frame(width: 54, alignment: .trailing)
            Text("Share")
                .frame(width: 52, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .textCase(.uppercase)
        .tracking(0.8)
        .foregroundStyle(.secondary)
        .padding(.bottom, 7)
        .accessibilityHidden(true)
    }

    private func color(for level: StudyMasteryLevel) -> Color {
        switch level {
        case .apprentice: .pink
        case .guru: .purple
        case .master: .blue
        case .enlightened: .orange
        case .burned: .green
        }
    }
}

#Preview("Item spread") {
    StudyMasterySpreadView(
        spread: StudyMasterySpread(
            apprentice: 42,
            guru: 54,
            master: 33,
            enlightened: 16,
            burned: 5
        )
    )
    .padding()
    .paperBackground()
}
