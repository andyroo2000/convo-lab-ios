import SwiftUI

struct JournalThinkingOrnament: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var openedAt = Date()
    @State private var deck = Array(JournalThinkingIllustrations.images.indices).shuffled()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { context in
            HStack(spacing: 16) {
                rule
                ForEach(0..<3) { slot in
                    illustration(slot: slot, elapsed: context.date.timeIntervalSince(openedAt))
                }
                rule
            }.frame(height: 47)
        }.accessibilityHidden(true).accessibilityIdentifier("JournalThinkingIllustrations")
    }

    private var rule: some View {
        VStack(spacing: 2) {
            Rectangle().frame(height: 1)
            Rectangle().frame(height: 1)
        }.foregroundStyle(Color(red: 0.608, green: 0.580, blue: 0.525).opacity(0.5))
            .frame(maxWidth: .infinity)
    }

    private func illustration(slot: Int, elapsed: Double) -> some View {
        let options = deck.enumerated().filter { $0.offset % 3 == slot }.map(\.element)
        let frame = JournalThinkingTiming.frame(elapsed: elapsed, slot: slot)
        return Group {
            if !options.isEmpty {
                Image(uiImage: JournalThinkingIllustrations.images[options[reduceMotion ? 0 : frame.turn % options.count]])
                    .resizable().scaledToFit().opacity(reduceMotion ? 1 : frame.opacity)
            }
        }.frame(width: 49, height: 41)
    }
}

struct JournalThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var openedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { context in
            HStack(spacing: 10) {
                ForEach(0..<3) { dot in
                    Circle().fill(Color(red: 0.388, green: 0.365, blue: 0.325))
                        .frame(width: 7, height: 7)
                        .opacity(reduceMotion ? 0.65 : JournalThinkingTiming.dot(elapsed: context.date.timeIntervalSince(openedAt), index: dot))
                }
            }.frame(height: 12)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("Your tutor is preparing your feedback. Your writing is saved.")
    }
}
