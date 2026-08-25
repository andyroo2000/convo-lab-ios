import SwiftUI

struct StudyMilestoneAwardView: View {
    let award: StudyMilestoneAward
    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationTrigger = 0
    @State private var canContinue = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 18)

            if reduceMotion {
                awardGraphic(values: .settled)
            } else {
                KeyframeAnimator(
                    initialValue: OrbitAnimationValues(),
                    trigger: animationTrigger
                ) { values in
                    awardGraphic(values: values)
                } keyframes: { _ in
                    orbitKeyframes
                }
            }

            VStack(spacing: 7) {
                Text(award.definition.title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(ConvoLabTheme.navy)
                    .multilineTextAlignment(.center)
                Text(award.definition.detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 390)
            }

            Spacer(minLength: 12)

            VStack(spacing: 8) {
                Button("Continue") {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .tint(ConvoLabTheme.navy)
                .controlSize(.large)
                .opacity(canContinue ? 1 : 0)
                .disabled(!canContinue)
                .accessibilityIdentifier("StudyMilestoneContinueButton")

                if !reduceMotion {
                    Button("Replay") {
                        canContinue = false
                        animationTrigger += 1
                    }
                    .buttonStyle(.plain)
                    .font(.footnote.bold())
                    .foregroundStyle(ConvoLabTheme.navy)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .accessibilityIdentifier("StudyMilestoneAward")
        .onAppear {
            animationTrigger += 1
        }
        .task(id: animationTrigger) {
            if reduceMotion {
                canContinue = true
                return
            }
            try? await Task.sleep(for: .milliseconds(4_800))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                canContinue = true
            }
        }
    }

    private func awardGraphic(values: OrbitAnimationValues) -> some View {
        ZStack {
            Circle()
                .stroke(ConvoLabTheme.cyan.opacity(0.16 * values.starOpacity), lineWidth: 2)
                .frame(width: 210, height: 210)

            ForEach(0..<8, id: \.self) { index in
                Image(systemName: "star.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(starColor(at: index))
                    .scaleEffect(values.starScale * starScaleVariance[index])
                    .opacity(values.starOpacity)
                    .offset(y: -105)
                    .rotationEffect(.degrees(Double(index) * 45 + values.angle))
            }

            Text(award.definition.badgeText)
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .foregroundStyle(ConvoLabTheme.cream)
                .frame(width: 112, height: 112)
                .background(badgeColor(progress: values.badgeColorProgress))
                .clipShape(.rect(cornerRadius: 34))
                .overlay {
                    RoundedRectangle(cornerRadius: 34)
                        .stroke(ConvoLabTheme.cyan.opacity(0.18), lineWidth: 8)
                }
                .shadow(color: ConvoLabTheme.navy.opacity(0.22), radius: 16, y: 9)
                .scaleEffect(values.badgeScale)
                .rotationEffect(.degrees(values.badgeRotation))
                .opacity(values.badgeOpacity)
        }
        .frame(width: 250, height: 250)
        .accessibilityHidden(true)
    }

    @KeyframesBuilder<OrbitAnimationValues>
    private var orbitKeyframes: some Keyframes<OrbitAnimationValues> {
        KeyframeTrack(\.angle) {
            LinearKeyframe(300, duration: 0.456)
            LinearKeyframe(650, duration: 0.912)
            LinearKeyframe(875, duration: 0.836)
            LinearKeyframe(1_010, duration: 0.722)
            LinearKeyframe(1_062, duration: 0.532)
            LinearKeyframe(1_080, duration: 0.342)
            LinearKeyframe(1_080, duration: 1)
        }
        KeyframeTrack(\.starScale) {
            CubicKeyframe(1.52, duration: 0.304)
            CubicKeyframe(1.46, duration: 0.38)
            CubicKeyframe(1.34, duration: 0.684)
            CubicKeyframe(1.22, duration: 0.836)
            CubicKeyframe(0.96, duration: 0.722)
            CubicKeyframe(0.82, duration: 0.532)
            CubicKeyframe(0.62, duration: 0.342)
            LinearKeyframe(0.62, duration: 1)
        }
        KeyframeTrack(\.starOpacity) {
            LinearKeyframe(1, duration: 0.18)
            LinearKeyframe(1, duration: 3.278)
            LinearKeyframe(0, duration: 0.342)
            LinearKeyframe(0, duration: 1)
        }
        KeyframeTrack(\.badgeScale) {
            SpringKeyframe(1.08, duration: 0.9, spring: .snappy)
            CubicKeyframe(1, duration: 0.5)
            LinearKeyframe(1, duration: 1.94)
            CubicKeyframe(1.055, duration: 0.24)
            CubicKeyframe(1, duration: 0.24)
            LinearKeyframe(1, duration: 0.98)
        }
        KeyframeTrack(\.badgeRotation) {
            SpringKeyframe(10, duration: 0.9, spring: .snappy)
            CubicKeyframe(0, duration: 0.5)
            LinearKeyframe(0, duration: 3.4)
        }
        KeyframeTrack(\.badgeOpacity) {
            LinearKeyframe(1, duration: 0.4)
            LinearKeyframe(1, duration: 4.4)
        }
        KeyframeTrack(\.badgeColorProgress) {
            LinearKeyframe(0, duration: 3.8)
            LinearKeyframe(1, duration: 1)
        }
    }

    private func badgeColor(progress: Double) -> Color {
        let progress = min(max(progress, 0), 1)
        return Color(
            red: (25.0 + (17.0 - 25.0) * progress) / 255.0,
            green: (72.0 + (51.0 - 72.0) * progress) / 255.0,
            blue: (115.0 + (92.0 - 115.0) * progress) / 255.0
        )
    }

    private func starColor(at index: Int) -> Color {
        [
            ConvoLabTheme.cyan,
            ConvoLabTheme.coral,
            .green,
            .yellow,
            .purple,
            .pink,
            .blue,
            .orange,
        ][index]
    }

    private var starScaleVariance: [Double] {
        [1, 0.96, 1.03, 0.98, 1.02, 0.95, 1.04, 0.97]
    }
}

private struct OrbitAnimationValues {
    var angle = 0.0
    var starScale = 0.68
    var starOpacity = 0.0
    var badgeScale = 0.28
    var badgeRotation = -170.0
    var badgeOpacity = 0.0
    var badgeColorProgress = 0.0

    static let settled = OrbitAnimationValues(
        angle: 1_080,
        starScale: 0,
        starOpacity: 0,
        badgeScale: 1,
        badgeRotation: 0,
        badgeOpacity: 1,
        badgeColorProgress: 1
    )
}

struct StudyRecentMilestonesSection: View {
    let awards: [StudyMilestoneAward]
    var title = "Recent milestones"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                ForEach(awards.prefix(3)) { award in
                    VStack(spacing: 7) {
                        StudyMilestoneBadge(definition: award.definition, isEarned: true)
                        Text(award.definition.title)
                            .font(.caption.bold())
                            .foregroundStyle(ConvoLabTheme.navy)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.82), in: .rect(cornerRadius: 18))
        .contentShape(.rect)
        .accessibilityIdentifier("StudyRecentMilestones")
    }
}

struct StudyMilestonesView: View {
    let store: StudyMilestoneStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !store.earnedAwards.isEmpty {
                    milestoneGroup(
                        title: "Earned",
                        definitions: store.earnedAwards.map(\.definition),
                        isEarned: true
                    )
                }

                if !store.upcomingMilestones.isEmpty {
                    milestoneGroup(
                        title: "Ahead",
                        definitions: store.upcomingMilestones,
                        isEarned: false
                    )
                }
            }
            .padding()
        }
        .paperBackground()
        .navigationTitle("Milestones")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func milestoneGroup(
        title: String,
        definitions: [StudyMilestoneDefinition],
        isEarned: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(ConvoLabTheme.navy)

            ForEach(definitions) { definition in
                HStack(spacing: 15) {
                    StudyMilestoneBadge(definition: definition, isEarned: isEarned)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(definition.title)
                            .font(.headline)
                            .foregroundStyle(ConvoLabTheme.navy)
                        Text(definition.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding()
                .background(.white.opacity(isEarned ? 0.82 : 0.5), in: .rect(cornerRadius: 18))
            }
        }
    }
}

private struct StudyMilestoneBadge: View {
    let definition: StudyMilestoneDefinition
    let isEarned: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(isEarned ? ConvoLabTheme.navy : ConvoLabTheme.navy.opacity(0.12))
            Text(definition.badgeText)
                .font(.system(size: 19, weight: .heavy, design: .rounded))
                .foregroundStyle(isEarned ? ConvoLabTheme.cream : .secondary)
        }
        .frame(width: 62, height: 62)
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(ConvoLabTheme.cyan.opacity(isEarned ? 0.22 : 0.08), lineWidth: 5)
        }
        .accessibilityHidden(true)
    }
}
