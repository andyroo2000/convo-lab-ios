# Time chart swipe regression and performance

The native UI fixture opens the real `StudyTimeView`, store, API client, and chart with an in-memory account and a URL protocol that serves synthetic analytics. It never contacts a production account. Four years of mixed study activity (about 17,500 sessions across six categories) are aggregated into the same day/week/month/year/all-time response shapes used by the API; a weekly chart still receives seven buckets.

## Regression

On iOS 26.2, the pan recognizer can ask whether a gesture should begin while its translation is still `(0, 0)`. Repeated native left swipes had a horizontal velocity of approximately `(-204, 0)` at that point. The previous translation-only check rejected them. Right swipes already had a nonzero translation and succeeded.

The direction check now falls back to velocity only when translation is zero. Established vertical or diagonal displacement still rejects the horizontal pan. A native test moves between previous and current weeks in both directions, verifies the selected period and totals, and exercises category filtering.

The pager also observes transient drag state separately from its prebuilt chart pages. Pending uncached navigation returns the chart to its resting position and displays a loading indicator. Changing range or leaving the view cancels the owned task; generation checks reject late navigation completions, and cancelled requests cannot publish stale analytics or cancellation errors.

## Measurement

A private 10 ms main-actor heartbeat records scheduling gaps without publishing SwiftUI state on each tick. Results are emitted only when measurement stops. These are scheduling gaps, **not display frame times**, and XCTest gesture/idle duration is not a direct interaction-latency measurement.

The comparable workload is three accepted rightward swipes into older weeks. The old build's rejected left swipes are excluded from timing comparisons. Native round trips and delayed-request cancellation are separate correctness checks. The synthetic transport has 40 ms normal latency and a longer controlled delay for the cancellation scenario.

The 2026-10-18 comparison used an iPhone 17 Pro simulator, iOS 26.2, Debug configuration, serial execution, and three repetitions per build. Baseline production source was `cf9e0864e09e6d0327f409bb8dfb557443ad8b1d`, with the same test fixture copied into a separate worktree. Each measured run transferred three prefetched responses totaling 44,344 bytes and represented 17,514 synthetic sessions.

| Metric, median across three runs | Baseline | Revised |
| --- | ---: | ---: |
| 95th-percentile main-actor scheduling gap | 38.569 ms | 16.715 ms |
| Gaps over 50 ms | 12 | 6 |
| Maximum scheduling gap | 83.249 ms | 90.449 ms |

The 95th-percentile gap decreased 56.7%, and gaps over 50 ms decreased 50%. The worst gap did not improve; occasional work when replacing a chart remains. This simulator comparison does not establish physical-device frame rates. The baseline failed all three return-swipe checks; the revised build completed all nine return swipes across the three runs.

Raw measurements are retained in `baseline.json`, `revised.json`, and `comparison.json` alongside this report.

## Reproduction

Use an available iPhone simulator ID for `SIMULATOR_ID` and a new result bundle path for each run:

```sh
xcodebuild test \
  -project ConvoLab.xcodeproj \
  -scheme ConvoLab \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -parallel-testing-enabled NO \
  -only-testing:ConvoLabUITests/TimeChartPerformanceUITests/testWeekSwipesRemainResponsiveAndPreserveNavigation \
  -test-iterations 3 \
  -resultBundlePath TimeChartResults.xcresult
```

The log emits `TIME_CHART_PERFORMANCE_JSON` records, and the result bundle retains JSON attachments and screenshots. Run the complete `TimeChartPerformanceUITests` class for the delayed-load cancellation check, and the normal shared scheme for the full repository gate. Timing thresholds intentionally do not fail CI on different hardware; navigation, totals, filters, cancellation, and continued interaction are asserted.
