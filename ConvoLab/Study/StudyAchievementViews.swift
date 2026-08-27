import SwiftUI

struct StudyAchievementBadgeCard: View {
    let achievement: PresentedStudyAchievement
    let imageURL: URL?

    var body: some View {
        VStack(spacing: 0) {
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
            .frame(width: 256, height: 256)
            .clipped()
            .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text(achievement.tier.title)
                    .font(.title3.bold())
                    .lineLimit(1)
                Text(detail)
                    .font(.subheadline.bold())
                    .foregroundStyle(ConvoLabTheme.cream.opacity(0.9))
                    .lineLimit(1)
            }
            .foregroundStyle(ConvoLabTheme.cream)
            .frame(width: 256)
            .frame(minHeight: 88)
            .background(achievement.isEarned ? ConvoLabTheme.navy : Color(red: 0.38, green: 0.44, blue: 0.48))
            .clipShape(
                UnevenRoundedRectangle(
                    cornerRadii: .init(bottomLeading: 18, bottomTrailing: 18),
                    style: .continuous
                )
            )
        }
        .frame(width: 256)
        .opacity(achievement.isEarned ? 1 : 0.9)
        .shadow(color: ConvoLabTheme.navy.opacity(0.12), radius: 0, y: 10)
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
        if achievement.isEarned { return "Earned" }
        guard let remaining = achievement.remaining else {
            let threshold = achievement.tier.threshold
            return "Start with \(threshold.formatted()) \(unit(for: threshold))"
        }
        return "\(remaining.formatted()) more \(unit(for: remaining))"
    }

    private func unit(for count: Int) -> String {
        guard count == 1 else { return achievement.family.unit }
        return [
            "cards": "card",
            "reviews": "review",
            "minutes": "minute",
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

            if store.catalog != nil {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(store.featuredAchievements) { achievement in
                            StudyAchievementBadgeCard(
                                achievement: achievement,
                                imageURL: store.imageURL(for: achievement)
                            )
                        }
                    }
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
                .padding(.top, 18)
            } else if store.isLoading {
                ProgressView("Loading achievements…")
                    .tint(ConvoLabTheme.navy)
                    .frame(maxWidth: .infinity, minHeight: 130)
            } else if let errorMessage = store.errorMessage {
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
        case all = "All badges"

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

                if let catalog = store.catalog {
                    switch selection {
                    case .progress:
                        progressView
                    case .all:
                        allBadgesView(catalog: catalog)
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
            Text("Your strongest earned badges and the achievements you’re closest to unlocking next.")
                .font(.body)
                .foregroundStyle(.secondary)

            ForEach(store.featuredAchievements) { achievement in
                StudyAchievementBadgeCard(
                    achievement: achievement,
                    imageURL: store.imageURL(for: achievement)
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func allBadgesView(catalog: StudyAchievementCatalog) -> some View {
        let achievementsByFamily = Dictionary(
            grouping: store.allAchievements,
            by: { $0.family.key }
        )
        return LazyVStack(alignment: .leading, spacing: 30) {
            ForEach(catalog.families, id: \.key) { family in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(family.title)
                            .font(.title2.bold())
                            .foregroundStyle(ConvoLabTheme.navy)
                        Text(familyProgress(family))
                            .font(.caption.bold())
                            .tracking(1)
                            .foregroundStyle(ConvoLabTheme.coral)
                    }

                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 18) {
                            ForEach(achievementsByFamily[family.key] ?? []) { achievement in
                                StudyAchievementBadgeCard(
                                    achievement: achievement,
                                    imageURL: store.imageURL(for: achievement)
                                )
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    private func familyProgress(_ family: StudyAchievementFamily) -> String {
        let value = store.progress?.revision == store.catalog?.revision
            ? store.progress?.metricValues[family.metricKey] ?? 0
            : 0
        return "\(value.formatted()) \(family.unit) so far".uppercased()
    }
}
