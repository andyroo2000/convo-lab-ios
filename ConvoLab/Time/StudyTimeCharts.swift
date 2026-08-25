import Charts
import SwiftUI

struct JLPTMasteryLevelBand: View {
    let level: String
    let caption: String
    let mastery: StudyJLPTLevelMastery

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("JLPT LEVEL")
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(ConvoLabTheme.coral)
                    Text(level)
                        .font(.title2.monospaced().weight(.black))
                        .foregroundStyle(ConvoLabTheme.navy)
                }
                Spacer()
                Text(caption.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(level), \(caption)")

            Divider()
                .accessibilityHidden(true)
            JLPTMasteryMetricRow(
                level: level,
                title: "Vocabulary",
                metric: mastery.vocabulary,
                tint: ConvoLabTheme.navy,
                showSourceBreakdown: true
            )
            Divider()
                .accessibilityHidden(true)
            JLPTMasteryMetricRow(
                level: level,
                title: "Grammar",
                metric: mastery.grammar,
                tint: ConvoLabTheme.coral
            )
        }
        .padding(16)
        .background(ConvoLabTheme.navy.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(ConvoLabTheme.navy.opacity(0.10), lineWidth: 1)
        }
    }
}

struct JLPTMasteryMetricRow: View {
    let level: String
    let title: String
    let metric: StudyJLPTMasteryMetric
    let tint: Color
    var showSourceBreakdown = false

    private var boundedPercent: Int {
        min(max(metric.masteryPercent, 0), 100)
    }

    private var matchedCount: Int {
        min(max(metric.matched ?? metric.covered, 0), metric.total)
    }

    private var knownCount: Int? {
        guard let known = metric.known else { return nil }
        return min(max(known, 0), metric.total)
    }

    private var knownFromCards: Int? {
        guard let value = metric.knownFromCards else { return nil }
        return min(max(value, 0), metric.total)
    }

    private var knownFromWaniKani: Int? {
        guard let value = metric.knownFromWaniKani else { return nil }
        return min(max(value, 0), metric.total)
    }

    private var knownFromBoth: Int? {
        guard let value = metric.knownFromBoth else { return nil }
        return min(max(value, 0), metric.total)
    }

    private var accessibilitySummary: String {
        let matched = "\(matchedCount) of \(metric.total) matched in your cards"
        guard let knownCount else {
            return "\(boundedPercent) percent, \(matched)"
        }
        var summary = "\(boundedPercent) percent, \(knownCount) of \(metric.total) known at Guru or above"
        if showSourceBreakdown, let knownFromCards {
            summary += ", \(knownFromCards) from ConvoLab cards"
        }
        if showSourceBreakdown, let knownFromWaniKani {
            summary += ", \(knownFromWaniKani) from WaniKani"
        }
        if showSourceBreakdown, let knownFromBoth, knownFromBoth > 0 {
            summary += ", \(knownFromBoth) counted in both"
        }
        return "\(summary), \(matched)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(boundedPercent)%")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            ProgressView(value: Double(boundedPercent), total: 100)
                .tint(tint)
            VStack(alignment: .leading, spacing: 2) {
                if let knownCount {
                    Text("\(knownCount) of \(metric.total) known (Guru+)")
                }
                if showSourceBreakdown, let knownFromCards {
                    Text("\(knownFromCards) from ConvoLab cards")
                        .padding(.leading, 12)
                }
                if showSourceBreakdown, let knownFromWaniKani {
                    Text("\(knownFromWaniKani) from WaniKani")
                        .padding(.leading, 12)
                }
                if showSourceBreakdown, let knownFromBoth, knownFromBoth > 0 {
                    Text("\(knownFromBoth) counted in both")
                        .padding(.leading, 12)
                }
                Text("\(matchedCount) of \(metric.total) matched in your cards")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(level) \(title) mastery")
        .accessibilityValue(accessibilitySummary)
    }
}

struct StudyRhythmChart: View {
    let analytics: StudyTimeAnalyticsRange
    let generatedAt: Date
    let includedCategories: Set<StudyActivityCategory>
    let onToggleCategory: (StudyActivityCategory) -> Void
    let onDrillDown: ((StudyTimeAnalyticsBucket) -> Void)?

    private var projection: StudyTimeAnalyticsProjection {
        StudyTimeAnalyticsProjection(
            analytics: analytics,
            generatedAt: generatedAt,
            includedCategories: includedCategories
        )
    }

    private var axisDates: [Date] {
        let step = switch analytics.key {
        case .today: 4
        case .month: 5
        default: 1
        }
        let lastIndex = analytics.buckets.count - 1

        return analytics.buckets.enumerated().compactMap { index, bucket in
            index.isMultiple(of: step) || index == lastIndex ? bucket.startsAt : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                metric("Total", milliseconds: projection.totalDurationMs)
                metric("Daily avg", milliseconds: projection.dailyAverageDurationMs)
                VStack(spacing: 4) {
                    Text("Best")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(projection.bestBucket.map(bestBucketLabel) ?? "—")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(
                        "\(studyTimeCompactDuration(projection.bestBucketDurationMs)) total"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }

            analyticsChart
                .frame(height: 210)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(StudyActivityCategory.allCases) { category in
                    legendItem(category)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var analyticsChart: some View {
        Chart {
            ForEach(analytics.buckets) { bucket in
                ForEach(projection.includedCategoryList) { category in
                    let milliseconds = bucket.duration(for: category)
                    if milliseconds > 0 {
                        BarMark(
                            x: .value("Period", bucket.startsAt),
                            y: .value("Minutes", Double(milliseconds) / 60_000),
                            width: .ratio(boldSlabWidthRatio)
                        )
                        .foregroundStyle(by: .value("Category", category.title))
                    }
                }
            }
        }
            .chartForegroundStyleScale(
                domain: projection.includedCategoryList.map(\.title),
                range: projection.includedCategoryList.map(\.chartColor)
            )
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) {
                            Text(axisDuration(minutes))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: axisDates) { value in
                    AxisGridLine()
                    if let date = value.as(Date.self) {
                        AxisValueLabel {
                            Text(axisLabel(date))
                        }
                    }
                }
            }
            .chartXScale(
                domain: projection.chartDomain,
                range: .plotDimension(padding: 4)
            )
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                        .simultaneousGesture(
                            SpatialTapGesture(count: 2)
                                .onEnded { value in
                                    handleChartDoubleTap(
                                        at: value.location,
                                        proxy: proxy,
                                        geometry: geometry
                                    )
                                }
                        )
                }
            }
            .accessibilityRepresentation {
                VStack {
                    ForEach(analytics.buckets) { bucket in
                        bucketAccessibilityElement(bucket)
                    }
                }
            }
    }

    private var boldSlabWidthRatio: CGFloat {
        switch analytics.key {
        case .today, .month:
            0.90
        case .week, .year, .all:
            0.82
        }
    }

    @ViewBuilder
    private func bucketAccessibilityElement(
        _ bucket: StudyTimeAnalyticsBucket
    ) -> some View {
        if let onDrillDown {
            Button(bestBucketLabel(bucket)) {
                onDrillDown(bucket)
            }
            .accessibilityLabel(bucketAccessibilityLabel(bucket))
            .accessibilityValue(studyTimeCompactDuration(projection.duration(for: bucket)))
            .accessibilityHint("Double-tap to open this period")
        } else {
            Text(bestBucketLabel(bucket))
                .accessibilityLabel(bucketAccessibilityLabel(bucket))
                .accessibilityValue(studyTimeCompactDuration(projection.duration(for: bucket)))
        }
    }

    private func bucketAccessibilityLabel(
        _ bucket: StudyTimeAnalyticsBucket
    ) -> String {
        let categorySummary = projection.includedCategoryList.compactMap { category in
            let duration = bucket.duration(for: category)
            return duration > 0 ? "\(category.title) \(studyTimeCompactDuration(duration))" : nil
        }
        return ([bestBucketLabel(bucket)] + categorySummary).joined(separator: ", ")
    }

    private func handleChartDoubleTap(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let onDrillDown,
              let plotFrame = proxy.plotFrame
        else {
            return
        }
        let frame = geometry[plotFrame]
        let xPosition = location.x - frame.minX
        guard xPosition >= 0,
              xPosition <= frame.width,
              let date: Date = proxy.value(atX: xPosition),
              let bucket = analytics.buckets.first(where: {
                  date >= $0.startsAt && date < $0.endsAt
              })
        else {
            return
        }
        onDrillDown(bucket)
    }

    private func legendItem(_ category: StudyActivityCategory) -> some View {
        let included = includedCategories.contains(category)
        let isOnlyIncludedCategory = included && includedCategories.count == 1

        return HStack(spacing: 8) {
            Circle()
                .fill(category.chartColor)
                .frame(width: 10, height: 10)
            Text(category.title)
            Spacer(minLength: 2)
            Text(studyTimeCompactDuration(projection.duration(for: category)))
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(included ? Color.primary : Color.secondary)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(
            included
                ? Color(uiColor: .secondarySystemBackground)
                : Color.secondary.opacity(0.08),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(
                    included ? category.chartColor : Color.secondary.opacity(0.2),
                    lineWidth: included ? 2 : 1
                )
        }
        .opacity(included ? 1 : 0.62)
        .contentShape(Capsule())
        .onTapGesture(count: 2) {
            guard !isOnlyIncludedCategory else { return }
            onToggleCategory(category)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(category.title)
        .accessibilityValue(
            "\(studyTimeCompactDuration(projection.duration(for: category))), "
                + (included ? "included" : "filtered out")
        )
        .accessibilityHint("Double-tap to toggle this category")
        .accessibilityAction {
            guard !isOnlyIncludedCategory else { return }
            onToggleCategory(category)
        }
    }

    private func axisLabel(_ date: Date) -> String {
        switch analytics.key {
        case .today:
            date.formatted(.dateTime.hour())
        case .week:
            date.formatted(.dateTime.weekday(.narrow))
        case .month:
            date.formatted(.dateTime.day())
        case .year:
            date.formatted(.dateTime.month(.narrow))
        case .all:
            date.formatted(.dateTime.year())
        }
    }

    private func metric(_ title: String, milliseconds: Int) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(studyTimeCompactDuration(milliseconds))
                .font(.headline)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private func bestBucketLabel(_ bucket: StudyTimeAnalyticsBucket) -> String {
        switch analytics.key {
        case .today:
            bucket.startsAt.formatted(.dateTime.hour())
        case .week:
            bucket.startsAt.formatted(.dateTime.weekday(.abbreviated))
        case .month:
            bucket.startsAt.formatted(.dateTime.day())
        case .year:
            bucket.startsAt.formatted(.dateTime.month(.abbreviated))
        case .all:
            bucket.startsAt.formatted(.dateTime.year())
        }
    }

    private func axisDuration(_ minutes: Double) -> String {
        if minutes >= 60 {
            return "\(Int(minutes / 60))h"
        }
        return "\(Int(minutes))m"
    }
}
