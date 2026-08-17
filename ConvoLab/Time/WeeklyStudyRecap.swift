import SwiftUI

struct WeeklyStudyRecapStats: Codable, Equatable {
    let totalMs: Int
    let activeDays: Int
    let reviewCount: Int
    let recallRate: Double?
    let newCardsIntroduced: Int
}

struct WeeklyStudyRecapCategories: Codable, Equatable {
    let review: Int
    let listen: Int
    let create: Int
    let immerse: Int
    let conversation: Int
    let wanikani: Int

    func duration(for category: StudyActivityCategory) -> Int {
        switch category {
        case .review: review
        case .listen: listen
        case .create: create
        case .immerse: immerse
        case .conversation: conversation
        case .wanikani: wanikani
        }
    }

    var total: Int { StudyActivityCategory.allCases.reduce(0) { $0 + duration(for: $1) } }
}

struct WeeklyStudyRecapWeek: Codable, Equatable {
    struct BestDay: Codable, Equatable {
        let date: String
        let totalMs: Int
    }

    let startsAt: Date
    let endsAt: Date
    let totalMs: Int
    let activeDays: Int
    let reviewCount: Int
    let recallRate: Double?
    let newCardsIntroduced: Int
    let bestDay: BestDay?
    let categories: WeeklyStudyRecapCategories
}

struct WeeklyStudyRecap: Codable, Equatable {
    let generatedAt: Date
    let week: WeeklyStudyRecapWeek
    let previousWeek: WeeklyStudyRecapStats
}

protocol WeeklyStudyRecapServing {
    func recap(timeZone: String, weekStartsOn: Int) async throws -> WeeklyStudyRecap
}

final class LiveWeeklyStudyRecapService: WeeklyStudyRecapServing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func recap(timeZone: String, weekStartsOn: Int) async throws -> WeeklyStudyRecap {
        try await api.request(
            "/api/study/weekly-recap",
            query: [
                URLQueryItem(name: "timezone", value: timeZone),
                URLQueryItem(name: "weekStartsOn", value: String(weekStartsOn)),
            ]
        )
    }
}

struct WeeklyStudyRecapView: View {
    let recap: WeeklyStudyRecap?
    let isLoading: Bool
    let errorMessage: String?
    let retry: () -> Void

    var body: some View {
        Group {
            if let recap {
                content(recap)
            } else if isLoading || errorMessage == nil {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Gathering last week’s highlights…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            } else if let errorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Button("Try again", action: retry)
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ recap: WeeklyStudyRecap) -> some View {
        let week = recap.week
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("LAST WEEK")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.purple)
                    Text("Your weekly recap")
                        .font(.title2.bold())
                    Text(period(for: week))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "calendar.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(.purple)
            }

            if WeeklyStudyRecapPresentation.isEmpty(week) {
                ContentUnavailableView(
                    "A fresh week",
                    systemImage: "sparkles",
                    description: Text("Your next study session will start a new recap.")
                )
            } else {
                Text(WeeklyStudyRecapPresentation.headline(for: week))
                    .font(.headline)
                    .foregroundStyle(ConvoLabTheme.navy)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    metric("Study time", compactDuration(week.totalMs), icon: "clock.fill")
                    metric("Active days", "\(week.activeDays) of 7", icon: "calendar")
                    metric("Recall", percent(week.recallRate), icon: "brain.head.profile")
                    metric("Reviews", "\(week.reviewCount)", icon: "rectangle.stack.fill")
                    metric("New cards", "\(week.newCardsIntroduced)", icon: "plus.rectangle.on.rectangle")
                }

                categoryMix(week.categories)
                bestDay(week.bestDay)
                comparison(week: week, previous: recap.previousWeek)
            }
        }
        .padding(.vertical, 6)
    }

    private func metric(_ label: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.purple)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.headline).foregroundStyle(ConvoLabTheme.navy)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func categoryMix(_ categories: WeeklyStudyRecapCategories) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where your time went").font(.headline)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(StudyActivityCategory.allCases) { category in
                        let value = categories.duration(for: category)
                        if value > 0 {
                            category.recapColor
                                .frame(width: geometry.size.width * CGFloat(value) / CGFloat(max(1, categories.total)))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            .accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(StudyActivityCategory.allCases) { category in
                    HStack(spacing: 7) {
                        Circle().fill(category.recapColor).frame(width: 8, height: 8)
                        Text(category.title).font(.caption).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(compactDuration(categories.duration(for: category)))
                            .font(.caption.weight(.bold))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func bestDay(_ bestDay: WeeklyStudyRecapWeek.BestDay?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("BEST DAY").font(.caption.weight(.bold)).foregroundStyle(.cyan)
                Text(bestDay.map { WeeklyStudyRecapPresentation.bestDayTitle($0.date) } ?? "No best day yet")
                    .font(.headline)
                if let bestDay { Text(compactDuration(bestDay.totalMs)).font(.subheadline) }
            }
            Spacer()
            Image(systemName: "trophy.fill").foregroundStyle(.yellow)
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(ConvoLabTheme.navy, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private func comparison(week: WeeklyStudyRecapWeek, previous: WeeklyStudyRecapStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compared with the week before").font(.headline)
            HStack {
                comparisonItem("Time", WeeklyStudyRecapPresentation.timeChange(week.totalMs, previous.totalMs))
                Divider()
                comparisonItem("Active days", signed(week.activeDays - previous.activeDays))
                Divider()
                comparisonItem("Recall", recallChange(week.recallRate, previous.recallRate))
            }
        }
        .padding(14)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func comparisonItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func period(for week: WeeklyStudyRecapWeek) -> String {
        let end = week.endsAt.addingTimeInterval(-1)
        return week.startsAt.formatted(.dateTime.month(.abbreviated).day()) + " – "
            + end.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func percent(_ value: Double?) -> String {
        value.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—"
    }

    private func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }

    private func recallChange(_ current: Double?, _ previous: Double?) -> String {
        guard let current, let previous else { return "—" }
        return signed(Int(((current - previous) * 100).rounded())) + " pts"
    }
}

enum WeeklyStudyRecapPresentation {
    static func isEmpty(_ week: WeeklyStudyRecapWeek) -> Bool {
        week.totalMs == 0 && week.reviewCount == 0 && week.newCardsIntroduced == 0
    }

    static func headline(for week: WeeklyStudyRecapWeek) -> String {
        if let recall = week.recallRate, recall >= 0.9 { return "Strong recall, steady progress" }
        if week.activeDays >= 5 { return "A steady week of Japanese" }
        let primary = StudyActivityCategory.allCases.max {
            week.categories.duration(for: $0) < week.categories.duration(for: $1)
        }
        if let primary, week.categories.duration(for: primary) > 0 { return "\(primary.title) led the way" }
        return "Progress worth keeping"
    }

    static func bestDayTitle(_ value: String, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return value }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: DateComponents(
            timeZone: timeZone, year: parts[0], month: parts[1], day: parts[2], hour: 12
        )) else { return value }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: date)
    }

    static func timeChange(_ current: Int, _ previous: Int) -> String {
        if current > 0, previous == 0 { return "New baseline" }
        guard previous > 0 else { return "No change" }
        let percent = Int((Double(current - previous) / Double(previous) * 100).rounded())
        return percent > 0 ? "+\(percent)%" : "\(percent)%"
    }
}

private extension StudyActivityCategory {
    var recapColor: Color {
        switch self {
        case .review: .blue
        case .listen: .cyan
        case .create: .orange
        case .immerse: .green
        case .conversation: .purple
        case .wanikani: .pink
        }
    }
}

private func compactDuration(_ milliseconds: Int) -> String {
    let minutes = max(0, milliseconds / 60_000)
    if minutes < 60 { return "\(minutes)m" }
    return minutes.isMultiple(of: 60) ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
}
