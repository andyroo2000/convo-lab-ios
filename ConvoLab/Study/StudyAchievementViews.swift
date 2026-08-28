import SwiftUI
import UIKit

struct StudyAchievementBadgeCard: View {
    let achievement: PresentedStudyAchievement
    let imageURL: URL?
    var isArtworkLoading = false
    var isNew = false
    var showsShadow = true

    var body: some View {
        VStack(spacing: -1) {
            Group {
                if let imageURL {
                    StudyAchievementLocalArtwork(imageURL: imageURL)
                } else if isArtworkLoading {
                    ProgressView()
                        .tint(ConvoLabTheme.navy)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ConvoLabTheme.cream)
                } else {
                    unavailableArtwork
                }
            }
            .frame(width: 128, height: 128)
            .clipped()
            .accessibilityHidden(true)

            VStack(spacing: 3) {
                Text(achievement.tier.title)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(detail)
                    .font(.caption2.bold())
                    .foregroundStyle(ConvoLabTheme.cream.opacity(0.9))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(ConvoLabTheme.cream)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(width: 128)
            .frame(height: 62)
            .background {
                UnevenRoundedRectangle(
                    cornerRadii: .init(bottomLeading: 10, bottomTrailing: 10),
                    style: .continuous
                )
                .fill(achievement.isEarned
                    ? ConvoLabTheme.navy
                    : Color(red: 0.38, green: 0.44, blue: 0.48))
            }
        }
        .frame(width: 128)
        .opacity(achievement.isEarned ? 1 : 0.9)
        .overlay(alignment: .topTrailing) {
            if isNew {
                Text("NEW")
                    .font(.caption2.bold())
                    .tracking(1.2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(ConvoLabTheme.coral, in: .capsule)
                    .padding(8)
            }
        }
        .shadow(
            color: showsShadow ? ConvoLabTheme.navy.opacity(0.12) : .clear,
            radius: 0,
            y: showsShadow ? 5 : 0
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(achievement.tier.title), \(detail)\(isNew ? ", New" : "")"
        )
        .accessibilityHint(achievement.tier.description)
        .accessibilityIdentifier("StudyAchievementBadge.\(achievement.id)")
    }

    private var unavailableArtwork: some View {
        Image(systemName: "photo.badge.exclamationmark")
            .font(.largeTitle)
            .foregroundStyle(ConvoLabTheme.navy.opacity(0.45))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ConvoLabTheme.cream)
    }

    private var detail: String {
        if achievement.isEarned { return achievement.tier.earnedDescription }
        guard let remaining = achievement.remaining else {
            let threshold = achievement.tier.threshold
            return "Start with \(threshold.formatted()) \(unit(for: threshold))"
        }
        return "\(remaining.formatted()) more \(unit(for: remaining))"
    }

    private func unit(for count: Int) -> String {
        guard count == 1 else { return achievement.family.unit }
        // Unknown catalog units remain unchanged rather than guessing at irregular plurals.
        return [
            "cards": "card",
            "reviews": "review",
            "hours": "hour",
        ][achievement.family.unit] ?? achievement.family.unit
    }
}

private struct StudyAchievementLocalArtwork: View {
    let imageURL: URL

    @State private var image: UIImage?
    @State private var didFinishLoading = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else if didFinishLoading {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(ConvoLabTheme.navy.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ConvoLabTheme.cream)
            } else {
                ProgressView()
                    .tint(ConvoLabTheme.navy)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ConvoLabTheme.cream)
            }
        }
        .task(id: imageURL) {
            image = nil
            didFinishLoading = false
            let data = await Self.loadData(from: imageURL)
            guard !Task.isCancelled else { return }
            if let data, let decodedImage = UIImage(data: data) {
                image = await decodedImage.byPreparingForDisplay() ?? decodedImage
            }
            didFinishLoading = true
        }
    }

    private nonisolated static func loadData(from url: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            try? Data(contentsOf: url, options: .mappedIfSafe)
        }.value
    }
}

struct StudyAchievementSpotlight: View {
    let store: StudyAchievementStore
    var newAchievementIDs: Set<String> = []

    var body: some View {
        let earnedAchievements = store.earnedAchievements
        let inProgressAchievements = store.inProgressAchievements

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ACHIEVEMENTS")
                    .font(.caption.bold())
                    .tracking(2)
                    .foregroundStyle(ConvoLabTheme.coral)
                Text("Your roar is growing")
                    .font(.title2.bold())
                    .foregroundStyle(ConvoLabTheme.navy)
            }

            if store.catalog != nil {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(earnedAchievements) { achievement in
                            StudyAchievementBadgeCard(
                                achievement: achievement,
                                imageURL: store.imageURL(for: achievement),
                                isArtworkLoading: store.isPreparingImage(for: achievement),
                                isNew: newAchievementIDs.contains(achievement.id)
                            )
                        }

                        if !inProgressAchievements.isEmpty {
                            nextUpMarker
                            ForEach(inProgressAchievements) { achievement in
                                StudyAchievementBadgeCard(
                                    achievement: achievement,
                                    imageURL: store.imageURL(for: achievement),
                                    isArtworkLoading: store.isPreparingImage(for: achievement)
                                )
                            }
                        }

                        if earnedAchievements.isEmpty,
                           inProgressAchievements.isEmpty {
                            Text("Your earned badges will appear here.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
                .padding(.top, 18)
                if let progressErrorMessage = store.progressErrorMessage {
                    Text(progressErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            } else if store.isLoading {
                ProgressView("Loading achievements…")
                    .tint(ConvoLabTheme.navy)
                    .frame(maxWidth: .infinity, minHeight: 130)
            } else if let errorMessage = store.progressErrorMessage ?? store.errorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Try again") {
                        Task { await store.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ConvoLabTheme.navy)
                }
                .padding(.vertical, 18)
            }

        }
        .padding(18)
        .background(.white.opacity(0.78), in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(ConvoLabTheme.navy.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: ConvoLabTheme.navy.opacity(0.08), radius: 12, y: 5)
        .accessibilityIdentifier("StudyAchievementSpotlight")
        .task {
            await store.refreshIfNeeded()
        }
    }

    private var nextUpMarker: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(ConvoLabTheme.coral.opacity(0.28))
                .frame(width: 2, height: 66)
            Text("NEXT\nUP")
                .font(.caption2.bold())
                .tracking(1.4)
                .foregroundStyle(ConvoLabTheme.coral)
                .multilineTextAlignment(.center)
            Capsule()
                .fill(ConvoLabTheme.coral.opacity(0.28))
                .frame(width: 2, height: 66)
        }
        .frame(width: 38, height: 190)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Next up")
    }
}

struct StudyAchievementAwardView: View {
    let achievement: PresentedStudyAchievement
    let imageURL: URL?
    let position: Int
    let total: Int
    let flightNamespace: Namespace.ID
    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var orbitAngle = 0.0
    @State private var orbitScale = 0.68
    @State private var starOpacity = 0.0
    @State private var badgeScale = 0.28
    @State private var badgeRotation = -170.0
    @State private var canContinue = false
    @State private var arrivalScale = 1.0

    private let colors: [Color] = [
        ConvoLabTheme.cyan, ConvoLabTheme.coral, .green, .yellow,
        .purple, .pink, .blue, .orange,
    ]

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(ConvoLabTheme.cyan.opacity(starOpacity * 0.16), lineWidth: 2)
                    .frame(width: 254, height: 254)
                    .accessibilityHidden(true)

                ForEach(colors.indices, id: \.self) { index in
                    Image(systemName: "star.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(colors[index])
                        .shadow(color: ConvoLabTheme.navy.opacity(0.24), radius: 4, y: 5)
                        .opacity(starOpacity)
                        .scaleEffect(orbitScale)
                        .offset(y: -142)
                        .rotationEffect(.degrees(Double(index) * 45))
                }
                .rotationEffect(.degrees(orbitAngle))
                .accessibilityHidden(true)

                AsyncImage(url: imageURL, transaction: Transaction(animation: nil)) { phase in
                    if case let .success(image) = phase {
                        image.resizable().interpolation(.high).scaledToFill()
                    } else {
                        Color.clear.overlay { ProgressView().tint(ConvoLabTheme.navy) }
                    }
                }
                .frame(width: 164, height: 164)
                .clipped()
                .scaleEffect(badgeScale * arrivalScale)
                .rotationEffect(.degrees(badgeRotation))
                .shadow(color: ConvoLabTheme.navy.opacity(0.22), radius: 16, y: 12)
                .matchedGeometryEffect(
                    id: "session-achievement-\(achievement.id)",
                    in: flightNamespace,
                    properties: .frame,
                    anchor: .center
                )
            }
            .frame(width: 318, height: 318)

            Text("ACHIEVEMENT EARNED")
                .font(.caption.bold())
                .tracking(2)
                .foregroundStyle(ConvoLabTheme.coral)
            Text(achievement.tier.title)
                .font(.largeTitle.bold())
                .foregroundStyle(ConvoLabTheme.navy)
                .multilineTextAlignment(.center)
            Text(achievement.tier.earnedDescription)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button(position < total ? "Next" : "Continue") { onContinue() }
                .buttonStyle(.borderedProminent)
                .tint(ConvoLabTheme.navy)
                .controlSize(.large)
                .opacity(canContinue ? 1 : 0)
                .disabled(!canContinue)
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("StudyAchievementAward")
        .task(id: achievement.id) { await playAnimation() }
    }

    private func playAnimation() async {
        if reduceMotion {
            orbitAngle = 1_080
            orbitScale = 0.62
            starOpacity = 0
            badgeScale = 1
            badgeRotation = 0
            canContinue = true
            return
        }
        if position > 1 {
            badgeScale = 1
            badgeRotation = 0
            starOpacity = 0
            try? await Task.sleep(for: .milliseconds(560))
            withAnimation(.easeOut(duration: 0.16)) { arrivalScale = 1.075 }
            try? await Task.sleep(for: .milliseconds(160))
            withAnimation(.easeInOut(duration: 0.22)) { arrivalScale = 1 }
        }
        orbitAngle = 0
        orbitScale = 0.68
        starOpacity = 0
        badgeScale = 0.28
        badgeRotation = -170
        canContinue = false
        withAnimation(.easeOut(duration: 0.25)) { starOpacity = 1 }
        withAnimation(.timingCurve(0.16, 0.84, 0.2, 1, duration: 4.8)) {
            orbitAngle = 1_080
            orbitScale = 0.62
            badgeScale = 1
            badgeRotation = 0
        }
        try? await Task.sleep(for: .seconds(4.35))
        withAnimation(.easeOut(duration: 0.45)) { starOpacity = 0 }
        try? await Task.sleep(for: .milliseconds(450))
        canContinue = true
    }
}
