# Prepared Time navigation and earlier startup charts

The Time screen now warms nearby periods with a controller-owned queue. It keeps one speculative request active and at most three desired periods: one step in the last navigation direction, two steps in that direction, then one step in the opposite direction. The initial direction is toward older periods. Future periods and all-time neighbors are excluded. Range changes replan the queue; leaving Time or backgrounding the app cancels it. A useful request survives a viewport change, and foreground requests can join it without losing their own cancellation ownership. Foreground work pauses the next speculative request.

Requests now ask the server for the ranges the chart needs. Week requests include week and month so daily month buckets can supply other fully covered weeks; other selections request their own range. The existing unscoped response remains supported. Shared requests are keyed by anchor and exact requested coverage. Intact scoped snapshots retain their separate coverage in memory and on disk, so a month response cannot satisfy a day/full request or evict a year response at the same anchor. The history envelope accepts the previous version and writes version 2 with optional scope metadata.

Startup synchronization first drains pending uploads. After that barrier, fresh analytics and the 93-day session replica load concurrently, allowing the chart to publish before history finishes downloading and merging. The upload acknowledgement advances the analytics epoch, preserving readable stale snapshots while rejecting older reads. A pending user selection survives that epoch and joins its new request; late startup work cannot replace a newer selection.

Every synchronization captures the account activation, token and mutation generation. Tokens are passed explicitly into session writes and reads, including the calendar-delete continuation. A new token cannot join an obsolete upload drain. Completed results carry the same context through the final await boundary and are applied only if it remains current. These guards are necessary because the independent reads and shared upload task can resume after navigation, edits or account changes. Existing local mutation guards and newer error messages remain authoritative.

## Controlled measurements

The startup fixture uses the real API client, a unique on-disk SwiftData store, an isolated UserDefaults cache, 2,631 remote history rows and 30 pending completions across six activities. It runs cold and previously cached startup three times each. Delays are fixed at 150 ms for upload, 1,200 ms for session history, and 200 ms for analytics. All records are compared with the server fixture after synchronization; every pending completion must be acknowledged. Recorded traffic proves no analytics request starts before upload completes.

The comparison uses PR2 `dd1328a` and this change on iPhone 17 Pro / iOS 26.2, with identical fixture sources and snapshot encoding, no concurrent builds, and three repetitions per scenario. Times below are medians and include activation.

| Startup measurement | PR2 | Scoped/concurrent requests |
| --- | ---: | ---: |
| Cold first fresh chart | 2,429.12 ms | 401.27 ms |
| Cached first readable chart | 105.12 ms | 102.09 ms |
| Cached first fresh chart | 2,275.91 ms | 569.13 ms |
| Cold full synchronization | 2,429.35 ms | 2,177.12 ms |
| Cached full synchronization | 2,276.16 ms | 2,032.12 ms |
| Cold maximum main-actor scheduling gap | 487.53 ms | 473.83 ms |
| Cached maximum main-actor scheduling gap | 149.57 ms | 150.85 ms |

Fresh chart readiness improves 83.5% cold and 75.0% cached in this controlled workload. Both versions make three requests and acknowledge all thirty uploads; peak in-flight requests changes from one to two, with no cancellations. The analytics response shrinks from 13,063 to 6,424 bytes. Full sync improves about 10%, while the later main-actor stall remains effectively unchanged: one cold or three cached gaps over 50 ms per run, and approximately 12.2 ms p95.

The prefetch fixture starts in October, allows the same 650 ms preparation window, then selects September, August, September and October. Each simulated analytics request takes 200 ms. The baseline warms the existing one adjacent period; the revised queue can prepare two older periods. The preparation window is excluded from traversal timing. Both versions use the same four visits and report preparation requests, requests during traversal, total requests and prepared coverage separately.

| Four-visit traversal measurement | Adjacent prefetch | Directional prefetch |
| --- | ---: | ---: |
| Median traversal time | 226.85 ms | 2.15 ms |
| Individual-run range | 218.05–238.40 ms | 2.00–26.45 ms |
| Older months ready after preparation | 1 | 2 |
| Requests during preparation | 1 | 2 |
| Requests awaited during traversal | 1 | 0 |
| Total requests, excluding initial October load | 2 | 2 |

The queue moves the remaining request into the preparation window; it does not reduce the total request count in this workload. All three repetitions have the same request counts.

These measure availability of chart models, not rendered frame timing or a production network SLA. Startup first-fresh readiness is separate from full replica synchronization. A later large history merge still runs on the main actor and remains a measured follow-up concern; overlapping it with analytics does not make that merge cheaper.

## Reproduction and verification

The normal scheme runs the startup fixture with 120 history rows, three pending completions and shorter delays, without timing thresholds. For the large fixture, copy the generated `.xctestrun` beside the original under `Build/Products` and set `EnvironmentVariables.TIME_STARTUP_LARGE` to `1` in each test-bundle dictionary (one containing `TestBundlePath`). Keeping the copy beside the original preserves its `__TESTROOT__` paths. Then run:

```sh
xcodebuild test-without-building \
  -xctestrun <derived-data>/Build/Products/TimeStartupLarge.xctestrun \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -parallel-testing-enabled NO \
  -only-testing:ConvoLabTests/StudyTimeStartupBenchmarkTests

xcodebuild test-without-building \
  -project ConvoLab.xcodeproj -scheme ConvoLab \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -derivedDataPath <derived-data> -parallel-testing-enabled NO -test-iterations 3 \
  -only-testing:ConvoLabTests/StudyTimePrefetchBenchmarkTests
```

Logs emit `TIME_STARTUP_JSON` and `TIME_PREFETCH_JSON`, also attached to result bundles. External artifacts under `time-analytics-series-20261019/ios-startup` and `ios-prefetch` preserve before/after JSON, measured source hashes, excluded fixture attempts and the history-merge profile.

Deterministic regressions cover exact scoped request sharing, persisted disjoint coverage, covered weeks, bounded queue order, foreground joining, obsolete completion ownership, upload retries, token rotation through calendar callbacks, A→B→A activation, selection changes during uploads/history, local mutations and newer error preservation. Native Time round-trip, category filtering and delayed navigation cancellation remain in the full scheme.
