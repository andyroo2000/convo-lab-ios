import SwiftUI

struct StudyTimeTimerRows: View {
    let store: StudyTimeStore
    @Binding var selectedActivity: StudyActivityKind
    @Binding var timerName: String

    @ViewBuilder
    var body: some View {
        Text("Timer")
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)

        Picker("Activity", selection: $selectedActivity) {
            ForEach([
                StudyActivityKind.cardCreation,
                .tv,
                .podcast,
                .reading,
                .conversation,
                .wanikaniReview,
                .other,
            ]) { activity in
                Text(activity.title).tag(activity)
            }
        }
        TextField("Source, show, or project (optional)", text: $timerName)
        if let active = store.active {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack {
                    VStack(alignment: .leading) {
                        Text(active.name ?? active.activity.title)
                            .font(.headline)
                        Text(
                            Duration.seconds(
                                context.date.timeIntervalSince(active.startedAt)
                            ),
                            format: .time(pattern: .hourMinuteSecond)
                        )
                        .monospacedDigit()
                        .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(active.name ?? active.activity.title)
                    .accessibilityValue("Timer running")
                    Spacer()
                    Button("Stop", role: .destructive) { store.stop() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            Button {
                store.start(
                    activity: selectedActivity,
                    source: .manual,
                    name: timerName.nilIfBlank
                )
            } label: {
                Label("Start session", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(ConvoLabTheme.navy)
        }
    }
}
