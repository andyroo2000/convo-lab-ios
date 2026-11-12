import SwiftUI

struct JournalProgressView: View {
    let status: JournalAnalysisStatus
    let serverTime: String
    @State private var openedAt = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: openedAt, by: 1)) { timeline in
            let elapsed = JournalProgressTiming.elapsed(serverTime: serverTime, openedAt: openedAt, now: timeline.date)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(status == .queued ? "Waiting to begin…" : "Reviewing your Japanese…").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(elapsed)s").font(.caption.monospacedDigit()).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                GeometryReader { geometry in
                    Capsule().fill(ConvoLabTheme.navy.opacity(0.12))
                    Capsule().fill(LinearGradient(colors: [ConvoLabTheme.navy, .purple, ConvoLabTheme.cyan], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * JournalProgressTiming.fraction(elapsed: elapsed, status: status))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 1), value: elapsed)
                }.frame(height: 8).accessibilityHidden(true)
                Text(elapsed >= 60
                     ? "Still working. Longer entries can take more time; your writing is saved."
                     : "Allow about 30–60 seconds for feedback. Your writing is saved.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(16).background(ConvoLabTheme.navy.opacity(0.06), in: .rect(cornerRadius: 16))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("JournalFeedbackProgress")
        }
    }
}

nonisolated enum JournalProgressTiming {
    static func elapsed(serverTime: String, openedAt: Date, now: Date) -> Int {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = formatter.date(from: serverTime) ?? ISO8601DateFormatter().date(from: serverTime)
        let age = parsed.map { openedAt.timeIntervalSince($0) } ?? -1
        let start = (0..<120).contains(age) ? (parsed ?? openedAt) : openedAt
        return max(0, Int(now.timeIntervalSince(start)))
    }

    // A waiting-time estimate, never a claim of measured model completion.
    static func fraction(elapsed: Int, status: JournalAnalysisStatus) -> Double {
        status == .queued ? 0.08 : min(0.94, 0.15 + 0.79 * (1 - exp(-Double(elapsed) / 35)))
    }
}
