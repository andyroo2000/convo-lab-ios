# Persisted nearby Time periods

Time now retains the twelve most recently received analytics responses across launches. Restored periods can be selected immediately, including weeks fully covered by a saved month's daily buckets. A restored selection always revalidates in the background; a failed refresh leaves its chart readable.

The history envelope is versioned and scoped to account, IANA timezone, and week-start convention. Each response retains its receipt time. Saving a later weekly recap cannot extend an older response's lifetime. Entries older than seven days, future receipt timestamps, incompatible versions, and mismatched contexts are ignored. Existing snapshots without a history envelope remain readable through the previous current-anchor fallback.

Freshness is evaluated for the requested range: open periods and the all-time aggregate use two minutes, closed periods use fifteen minutes. An open snapshot also becomes stale at the next local calendar day, even if its timer has not elapsed. Disk restores are always stale. Cached selection does not write to storage; an accepted response or recap saves the bounded snapshot synchronously, preserving save/delete ordering. Deleted or deactivated requests cannot recreate it, including a weekly recap that completes after deletion.

Each stored blob is additionally capped at 512 KiB. An oversized response removes the affected cached blob; an oversized existing blob is removed before decoding. This optional cache can always be rebuilt from the server. Dates use reference-date numbers to preserve fractional receipt times and period boundaries exactly, with read compatibility for existing ISO-8601 snapshots. Freshness still uses wall-clock time: backwards jumps before receipt invalidate an entry, but a smaller clock adjustment can change its remaining lifetime. Restores always revalidate, and midnight/context checks remain in force; monotonic in-process expiry is deferred.

## Controlled relaunch measurement

`StudyTimePersistentCacheBenchmarkTests` warms three anchors (October 18, September 1, and August 1), releases the first controller, creates another controller using the same isolated UserDefaults suite, and selects September's month. Timing includes construction, disk restoration, and availability of the selected chart model. Initial warming is excluded. The same relaunch test ran three times against unchanged PR1 production code (`ff5cb5f1`) and three times against PR2 on iPhone 17 Pro / iOS 26.2, with a fixed 200 ms mock transport delay and no concurrent builds.

| Measurement | PR1 | Persisted history |
| --- | ---: | ---: |
| Mean first chart model availability | 227.42 ms | 2.79 ms |
| Individual runs | 233.35, 232.76, 216.16 ms | 4.15, 2.03, 2.21 ms |
| Requests awaited before readiness | 1 | 0 |
| Total requests after revalidation | 1 | 1 |

This is a 98.8% reduction in the controlled readiness interval. It does not claim fewer refreshes, native rendering latency, or production network timings. The normal background request still runs once; persistence removes the wait before showing the saved chart.

The write-cost benchmark fills twelve complete five-range responses with six categories per bucket (211,699 encoded bytes), then performs thirty synchronous encode/save submissions per repetition. Across three repetitions, mean main-actor work was 6.48 ms, per-run p95 was 6.34–7.05 ms, and the worst sample was 16.26 ms. This measures JSON encoding and UserDefaults submission, not a physical-storage durability barrier. Storage remains bounded; asynchronous write coordination is deferred unless device measurements justify its added lifecycle complexity.

## Verification and reproduction

Focused coverage includes actual UserDefaults round trips, bounded eviction, unknown versions, partial known coverage, account/timezone/week-start isolation, stale revalidation failure, midnight/open/closed freshness, negative clocks, and late analytics/recap callbacks after deletion or deactivation. Existing transport tests explicitly inject the empty cache to avoid sharing prior test history. Native Time round-trip, filtering, and delayed-navigation cancellation tests remain part of the full scheme.

Run the benchmark after building the test targets:

```sh
xcodebuild test-without-building \
  -project ConvoLab.xcodeproj -scheme ConvoLab \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -derivedDataPath <derived-data> \
  -parallel-testing-enabled NO -test-iterations 3 \
  -only-testing:ConvoLabTests/StudyTimePersistentCacheBenchmarkTests
```

Logs emit `TIME_PERSISTENT_CACHE_JSON` and attach the measurements to the result bundle. Full validation artifacts, before/after JSON, source hashes, failed harness attempts, and the corrected test/runtime diagnosis are saved externally under `time-analytics-series-20261019/ios-persistent-cache`.

The next change will add requested-range transport and bounded directional prefetch. Before accepting partial responses at the same anchor, the record identity must preserve their disjoint coverage; this PR retains the existing full-response transport contract.
