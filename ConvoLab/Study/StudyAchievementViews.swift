import SwiftUI

struct StudyAchievementBadgeCard: View {
    let achievement: PresentedStudyAchievement
    let imageURL: URL?

    var body: some View {
        VStack(spacing: -1) {
            Group {
                if let imageURL {
                    AsyncImage(url: imageURL, transaction: Transaction(animation: .easeInOut)) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .interpolation(.high)
                                .scaledToFill()
                        case .failure:
                            unavailableArtwork
                        case .empty:
                            ProgressView()
                                .tint(ConvoLabTheme.navy)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(ConvoLabTheme.cream)
                        @unknown default:
                            unavailableArtwork
                        }
                    }
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
        .shadow(color: ConvoLabTheme.navy.opacity(0.12), radius: 0, y: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(achievement.tier.title), \(detail)")
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

struct StudyAchievementSpotlight: View {
    let store: StudyAchievementStore
    let milestoneStore: StudyMilestoneStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ACHIEVEMENTS")
                        .font(.caption.bold())
                        .tracking(2)
                        .foregroundStyle(ConvoLabTheme.coral)
                    Text("Your roar is growing")
                        .font(.title2.bold())
                        .foregroundStyle(ConvoLabTheme.navy)
                }
                Spacer(minLength: 8)
                NavigationLink {
                    StudyAchievementsView(store: store, milestoneStore: milestoneStore)
                } label: {
                    Label("View all", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.bold())
                        .foregroundStyle(ConvoLabTheme.navy)
                        .padding(.vertical, 8)
                }
            }

            if store.catalog != nil,
               store.progress != nil || store.progressErrorMessage == nil {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(store.recentAchievements) { achievement in
                            StudyAchievementBadgeCard(
                                achievement: achievement,
                                imageURL: store.imageURL(for: achievement)
                            )
                        }
                        if store.recentAchievements.isEmpty {
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
}

struct StudyAchievementsView: View {
    private enum Selection: String, CaseIterable, Identifiable {
        case progress = "In progress"
        case earned = "Earned"

        var id: Self { self }
    }

    let store: StudyAchievementStore
    let milestoneStore: StudyMilestoneStore
    @State private var selection = Selection.progress

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ACHIEVEMENTS")
                        .font(.caption.bold())
                        .tracking(2)
                        .foregroundStyle(ConvoLabTheme.coral)
                    Text("Your roar is growing")
                        .font(.largeTitle.bold())
                        .foregroundStyle(ConvoLabTheme.navy)
                }

                Picker("Achievement view", selection: $selection) {
                    ForEach(Selection.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                NavigationLink {
                    StudyMilestonesView(store: milestoneStore)
                } label: {
                    Label("Review milestone history", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.bold())
                        .foregroundStyle(ConvoLabTheme.navy)
                }

                if store.catalog != nil {
                    if let progressErrorMessage = store.progressErrorMessage {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(progressErrorMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Try again") {
                                Task { await store.refresh() }
                            }
                            .font(.subheadline.bold())
                        }
                    }
                    switch selection {
                    case .progress:
                        progressView
                    case .earned:
                        if store.progress != nil || store.progressErrorMessage == nil {
                            earnedBadgesView
                        }
                    }
                } else if store.isLoading {
                    ProgressView("Loading achievements…")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if let errorMessage = store.errorMessage {
                    ContentUnavailableView {
                        Label("Badge cabinet unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again") {
                            Task { await store.refresh() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ConvoLabTheme.navy)
                    }
                }
            }
            .padding()
        }
        .paperBackground()
        .navigationTitle("Achievements")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .task { await store.refreshIfNeeded() }
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("The achievements you’re closest to unlocking next.")
                .font(.body)
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 128, maximum: 128), spacing: 16)],
                alignment: .leading,
                spacing: 20
            ) {
                ForEach(store.inProgressAchievements) { achievement in
                    StudyAchievementBadgeCard(
                        achievement: achievement,
                        imageURL: store.imageURL(for: achievement)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var earnedBadgesView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Every badge you’ve earned, newest first.")
                .font(.body)
                .foregroundStyle(.secondary)

            if store.earnedAchievements.isEmpty {
                Text("Your earned badges will appear here.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 128, maximum: 128), spacing: 16)],
                    alignment: .leading,
                    spacing: 20
                ) {
                    ForEach(store.earnedAchievements) { achievement in
                        StudyAchievementBadgeCard(
                            achievement: achievement,
                            imageURL: store.imageURL(for: achievement)
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
