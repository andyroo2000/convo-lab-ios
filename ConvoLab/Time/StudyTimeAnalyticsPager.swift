import SwiftUI

@MainActor
@Observable
final class StudyTimeAnalyticsMotion {
    var dragOffset = CGFloat.zero
    var isSettling = false
    var isLoading = false
    @ObservationIgnored private var navigationGeneration = 0
    @ObservationIgnored private var navigationTask: Task<Void, Never>?

    // No actor-bound teardown; avoid isolated-deinit runtime failures on iOS 26.2.
    nonisolated deinit {}

    func reset() {
        dragOffset = 0
        isSettling = false
        isLoading = false
    }

    func cancelNavigation() {
        navigationGeneration += 1
        navigationTask?.cancel()
        navigationTask = nil
        reset()
    }

    func startNavigation(
        settling: Bool = false,
        operation: @escaping @MainActor (Int) async -> Void
    ) {
        navigationTask?.cancel()
        navigationGeneration += 1
        let generation = navigationGeneration
        isSettling = settling
        isLoading = false
        navigationTask = Task {
            defer {
                if isCurrentNavigation(generation) { navigationTask = nil }
            }
            guard !Task.isCancelled, isCurrentNavigation(generation) else { return }
            await operation(generation)
        }
    }

    func isCurrentNavigation(_ generation: Int) -> Bool {
        navigationGeneration == generation
    }

    func finishNavigation(_ generation: Int, action: () -> Void = {}) {
        guard isCurrentNavigation(generation) else { return }
        action()
        reset()
    }
}

/// Only this container observes per-frame motion. Its chart pages are built by
/// the parent when their data changes, rather than again for every pan sample.
struct StudyTimeAnalyticsPager<Page: View>: View {
    let motion: StudyTimeAnalyticsMotion
    let current: Page
    let previous: Page?
    let next: Page?
    let width: CGFloat
    let canSwipe: Bool
    let canNavigateLater: Bool
    let onEnded: (CGPoint, CGFloat) -> Void
    let onCancelled: () -> Void

    private var offset: CGFloat {
        guard motion.dragOffset < 0, !canNavigateLater else { return motion.dragOffset }
        let magnitude = abs(motion.dragOffset)
        return -42 * (1 - exp(-magnitude / 110))
    }

    var body: some View {
        ZStack {
            if let previous {
                preview(previous, at: -width + offset)
            }
            current.offset(x: offset)
            if let next {
                preview(next, at: width + offset)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            HorizontalStudyTimePanGesture(
                isEnabled: canSwipe && !motion.isSettling,
                onChanged: { motion.dragOffset = $0 },
                onEnded: onEnded,
                onCancelled: onCancelled
            )
        )
        .overlay(alignment: .topLeading) {
            if motion.isLoading {
                ProgressView("Loading period…")
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("StudyTimeAnalyticsLoading")
            }
        }
    }

    private func preview(_ page: Page, at offset: CGFloat) -> some View {
        page.offset(x: offset)
            .allowsHitTesting(false)
            .accessibilityRepresentation { EmptyView() }
            .accessibilityHidden(true)
    }
}
