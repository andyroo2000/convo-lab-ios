import SwiftUI
import UIKit

enum StudyTimeSwipeRecognition {
    enum Navigation: Equatable {
        case previous
        case next
        case snapBack
    }

    static func isHorizontal(translation: CGPoint, velocity: CGPoint = .zero) -> Bool {
        // UIKit can ask before translation is populated, particularly for left swipes.
        let direction = translation == .zero ? velocity : translation
        return abs(direction.x) > abs(direction.y)
    }

    static func navigation(
        translation: CGPoint,
        projectedTranslationX: CGFloat,
        canNavigateLater: Bool
    ) -> Navigation {
        guard isHorizontal(translation: translation) else { return .snapBack }
        if max(translation.x, projectedTranslationX) > 70 {
            return .previous
        }
        if min(translation.x, projectedTranslationX) < -70, canNavigateLater {
            return .next
        }
        return .snapBack
    }
}
struct HorizontalStudyTimePanGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (_ translation: CGPoint, _ projectedTranslationX: CGFloat) -> Void
    let onCancelled: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var configuration: HorizontalStudyTimePanGesture

        init(configuration: HorizontalStudyTimePanGesture) {
            self.configuration = configuration
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard configuration.isEnabled,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer
            else {
                return false
            }
            return StudyTimeSwipeRecognition.isHorizontal(
                translation: pan.translation(in: pan.view),
                velocity: pan.velocity(in: pan.view)
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(configuration: self)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.cancelsTouchesInView = false
        recognizer.maximumNumberOfTouches = 1
        if recognizer.isEnabled != isEnabled { recognizer.isEnabled = isEnabled }
        return recognizer
    }

    func updateUIGestureRecognizer(
        _ recognizer: UIPanGestureRecognizer,
        context: Context
    ) {
        context.coordinator.configuration = self
        if recognizer.isEnabled != isEnabled { recognizer.isEnabled = isEnabled }
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UIPanGestureRecognizer,
        context: Context
    ) {
        let configuration = context.coordinator.configuration
        let translation = recognizer.translation(in: recognizer.view)
        switch recognizer.state {
        case .began, .changed:
            configuration.onChanged(translation.x)
        case .ended:
            let velocity = recognizer.velocity(in: recognizer.view).x
            configuration.onEnded(translation, translation.x + velocity * 0.2)
        case .cancelled, .failed:
            configuration.onCancelled()
        default:
            break
        }
    }
}

extension StudyTimeView {
    func swipeableAnalytics(
        _ analytics: StudyTimeAnalyticsRange
    ) -> some View {
        let previous = adjacentAnalytics(by: -1)
        let next = canNavigateLater(from: analytics) ? adjacentAnalytics(by: 1) : nil
        return StudyTimeAnalyticsPager(
            motion: analyticsMotion,
            current: analyticsPage(
                analytics,
                generatedAt: store.analytics?.generatedAt ?? .now
            ),
            previous: previous.map { analyticsPage($0.range, generatedAt: $0.generatedAt) },
            next: next.map { analyticsPage($0.range, generatedAt: $0.generatedAt) },
            width: analyticsCardWidth,
            canSwipe: selectedRange != .all,
            canNavigateLater: canNavigateLater(from: analytics),
            onEnded: { translation, projectedTranslationX in
                finishAnalyticsPan(
                    translation: translation,
                    projectedTranslationX: projectedTranslationX,
                    analytics: analytics
                )
            },
            onCancelled: snapAnalyticsBack
        )
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        analyticsCardWidth = max(geometry.size.width, 1)
                    }
                    .onChange(of: geometry.size.width) { _, width in
                        analyticsCardWidth = max(width, 1)
                    }
            }
        }
        .task(
            id: "\(store.analytics?.anchorDate ?? "")"
                + "-\(selectedRange.rawValue)-\(store.analyticsCacheGeneration)"
        ) {
            store.updateAnalyticsPrefetching(range: selectedRange)
        }
        .accessibilityActions {
            if selectedRange != .all {
                Button("Previous period") {
                    navigateAnalytics(by: -1, from: analytics)
                }
                if canNavigateLater(from: analytics) {
                    Button("Next period") {
                        navigateAnalytics(by: 1, from: analytics)
                    }
                }
            }
        }
    }

    func analyticsPage(
        _ analytics: StudyTimeAnalyticsRange,
        generatedAt: Date
    ) -> some View {
        let drillDownAction: ((StudyTimeAnalyticsBucket) -> Void)? =
            if analytics.key.drillDownTarget == nil {
                nil
            } else {
                { bucket in drillDown(bucket) }
            }

        return VStack(alignment: .leading, spacing: 8) {
            if selectedRange != .all {
                Text(periodLabel(analytics))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            StudyRhythmChart(
                analytics: analytics,
                generatedAt: generatedAt,
                includedCategories: includedCategories,
                availableWidth: analyticsCardWidth,
                onToggleCategory: toggleCategory,
                onDrillDown: drillDownAction
            )
        }
    }

    func toggleCategory(_ category: StudyActivityCategory) {
        guard !includedCategories.contains(category) || includedCategories.count > 1 else {
            return
        }
        if includedCategories.contains(category) {
            includedCategories.remove(category)
        } else {
            includedCategories.insert(category)
        }
    }

    func drillDown(_ bucket: StudyTimeAnalyticsBucket) {
        guard let nextRange = selectedRange.drillDownTarget else { return }
        cancelAnalyticsNavigation()
        scheduleAnalyticsLoad(anchorDate: bucket.startsAt, selecting: nextRange)
    }

    func cancelAnalyticsNavigation() {
        analyticsMotion.cancelNavigation()
    }

    func scheduleAnalyticsLoad(
        anchorDate: Date, selecting range: StudyTimeRange? = nil, fallback: StudyTimeRange? = nil
    ) {
        let target = range ?? selectedRange
        analyticsMotion.startNavigation { navigationGeneration in
            let loaded = await store.loadAnalytics(anchorDate: anchorDate, range: target)
            guard !Task.isCancelled, analyticsMotion.isCurrentNavigation(navigationGeneration) else { return }
            guard loaded else {
                restoreAnalyticsRange(fallback)
                return
            }
            restoreAnalyticsRange(range)
        }
    }

    private func restoreAnalyticsRange(_ range: StudyTimeRange?) {
        StudyTimeRangeSelection.assign(
            range, selected: &selectedRange, suppressNextReset: &suppressNextHistoricalRangeReset
        )
    }

    func adjacentAnalytics(
        by amount: Int
    ) -> (range: StudyTimeAnalyticsRange, generatedAt: Date)? {
        guard let anchor = shiftedAnalyticsAnchor(by: amount),
              let cached = store.cachedAnalytics(anchorDate: anchor, range: selectedRange),
              let range = cached.range(selectedRange)
        else {
            return nil
        }
        return (range, cached.generatedAt)
    }

    func finishAnalyticsPan(
        translation: CGPoint,
        projectedTranslationX: CGFloat,
        analytics: StudyTimeAnalyticsRange
    ) {
        guard selectedRange != .all, !analyticsMotion.isSettling else { return }
        switch StudyTimeSwipeRecognition.navigation(
            translation: translation,
            projectedTranslationX: projectedTranslationX,
            canNavigateLater: canNavigateLater(from: analytics)
        ) {
        case .previous:
            completeAnalyticsSwipe(by: -1)
        case .next:
            completeAnalyticsSwipe(by: 1)
        case .snapBack:
            snapAnalyticsBack()
        }
    }

    func navigateAnalytics(
        by amount: Int,
        from analytics: StudyTimeAnalyticsRange
    ) {
        guard selectedRange != .all else { return }
        if amount > 0, !canNavigateLater(from: analytics) { return }
        completeAnalyticsSwipe(by: amount)
    }

    func completeAnalyticsSwipe(by amount: Int) {
        guard !analyticsMotion.isSettling,
              let nextAnchor = shiftedAnalyticsAnchor(by: amount)
        else {
            return
        }

        let outgoingOffset = amount < 0 ? analyticsCardWidth : -analyticsCardWidth

        analyticsMotion.startNavigation(settling: true) { navigationGeneration in
            var ready = store.cachedAnalytics(anchorDate: nextAnchor, range: selectedRange) != nil
            if !ready {
                analyticsMotion.isLoading = true
                snapAnalyticsBack()
                ready = await store.prefetchAnalytics(
                    anchorDate: nextAnchor,
                    range: selectedRange,
                    reportFailure: true
                )
            }
            guard !Task.isCancelled,
                  analyticsMotion.isCurrentNavigation(navigationGeneration)
            else { return }
            analyticsMotion.isLoading = false
            guard ready else {
                snapAnalyticsBack()
                analyticsMotion.finishNavigation(navigationGeneration)
                return
            }

            if reduceMotion {
                analyticsMotion.finishNavigation(navigationGeneration) {
                    _ = store.selectCachedAnalytics(anchorDate: nextAnchor, range: selectedRange)
                }
                return
            }

            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.9)) {
                analyticsMotion.dragOffset = outgoingOffset
            } completion: {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    analyticsMotion.finishNavigation(navigationGeneration) {
                        let selected = store.selectCachedAnalytics(anchorDate: nextAnchor, range: selectedRange)
                        if !selected {
                            entryErrorMessage =
                                "Study time changed while navigating. Swipe again to reload."
                        }
                    }
                }
            }
        }
    }

    func snapAnalyticsBack() {
        guard analyticsMotion.dragOffset != 0 else { return }
        if reduceMotion {
            analyticsMotion.dragOffset = 0
        } else {
            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.72)) {
                analyticsMotion.dragOffset = 0
            }
        }
    }

    func shiftedAnalyticsAnchor(by amount: Int) -> Date? {
        let calendar = Calendar.current
        guard let anchorDate = store.analytics?.anchorDate,
              let analyticsAnchor = analyticsAnchorDate(from: anchorDate)
        else {
            return nil
        }
        switch selectedRange {
        case .today:
            return calendar.date(byAdding: .day, value: amount, to: analyticsAnchor)
        case .week:
            return calendar.date(byAdding: .day, value: amount * 7, to: analyticsAnchor)
        case .month:
            guard let start = calendar.dateInterval(of: .month, for: analyticsAnchor)?.start else {
                return nil
            }
            return calendar.date(byAdding: .month, value: amount, to: start)
        case .year:
            guard let start = calendar.dateInterval(of: .year, for: analyticsAnchor)?.start else {
                return nil
            }
            return calendar.date(byAdding: .year, value: amount, to: start)
        case .all:
            return nil
        }
    }

    func canNavigateLater(from analytics: StudyTimeAnalyticsRange) -> Bool {
        guard selectedRange != .all, let generatedAt = store.analytics?.generatedAt else {
            return false
        }
        return analytics.endsAt <= generatedAt
    }

    func periodLabel(_ analytics: StudyTimeAnalyticsRange) -> String {
        let inclusiveEnd = analytics.endsAt.addingTimeInterval(-1)
        switch analytics.key {
        case .today:
            return analytics.startsAt.formatted(
                .dateTime.weekday(.wide).month(.wide).day().year()
            )
        case .week:
            return "\(analytics.startsAt.formatted(.dateTime.month(.abbreviated).day()))"
                + " – "
                + inclusiveEnd.formatted(.dateTime.month(.abbreviated).day().year())
        case .month:
            return analytics.startsAt.formatted(.dateTime.month(.wide).year())
        case .year:
            return analytics.startsAt.formatted(.dateTime.year())
        case .all:
            return ""
        }
    }

    func analyticsAnchorDate(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}
