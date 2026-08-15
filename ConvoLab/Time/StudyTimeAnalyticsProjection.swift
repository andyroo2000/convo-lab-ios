import Foundation

/// Pure presentation values derived from one analytics range and category selection.
/// Keeping these rules outside SwiftUI lets every analytics surface share the same totals.
struct StudyTimeAnalyticsProjection {
    let analytics: StudyTimeAnalyticsRange
    let generatedAt: Date
    let includedCategories: Set<StudyActivityCategory>
    let calendar: Calendar

    init(
        analytics: StudyTimeAnalyticsRange,
        generatedAt: Date,
        includedCategories: Set<StudyActivityCategory>,
        calendar: Calendar = .current
    ) {
        self.analytics = analytics
        self.generatedAt = generatedAt
        self.includedCategories = includedCategories
        self.calendar = calendar
    }

    var includedCategoryList: [StudyActivityCategory] {
        StudyActivityCategory.allCases.filter(includedCategories.contains)
    }

    var totalDurationMs: Int {
        analytics.duration(for: includedCategories)
    }

    var elapsedDayCount: Int {
        let effectiveEnd = min(generatedAt, analytics.endsAt)
        let startDay = calendar.startOfDay(for: analytics.startsAt)
        let endDay = calendar.startOfDay(for: effectiveEnd)
        let dayDistance = calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0

        // Fixed periods end at the exclusive boundary of their final day. Once
        // complete, counting that boundary again would turn a week into eight days.
        let includesEffectiveEndDay = analytics.key == .all || effectiveEnd < analytics.endsAt
        return max(1, dayDistance + (includesEffectiveEndDay ? 1 : 0))
    }

    var dailyAverageDurationMs: Int {
        totalDurationMs / elapsedDayCount
    }

    var bestBucket: StudyTimeAnalyticsBucket? {
        analytics.buckets
            .filter { duration(for: $0) > 0 }
            .max { duration(for: $0) < duration(for: $1) }
    }

    var bestBucketDurationMs: Int {
        bestBucket.map(duration(for:)) ?? 0
    }

    /// The selected period always fills the chart, including its future portion.
    var chartDomain: ClosedRange<Date> {
        min(analytics.startsAt, analytics.endsAt)...max(analytics.startsAt, analytics.endsAt)
    }

    func duration(for bucket: StudyTimeAnalyticsBucket) -> Int {
        bucket.duration(for: includedCategories)
    }

    func duration(for category: StudyActivityCategory) -> Int {
        analytics.duration(for: category)
    }
}
