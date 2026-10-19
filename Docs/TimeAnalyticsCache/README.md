# Time analytics period cache

Period navigation now reuses chart data by calendar boundary, rather than only
by the literal anchor date sent to the API. A month or year can be selected again
without a request, and a complete week can be built from one cached month's daily
buckets. Day charts still require hourly data; incomplete or cross-month coverage
does not invent empty buckets.

Sync advances the data generation while retaining usable charts. A stale chart
can be displayed immediately and revalidated. Shared in-flight requests have
individual consumers: cancelling a prefetch does not cancel another navigation
waiting for the same response. Account, timezone, data generation, and visible
navigation ownership prevent obsolete responses from taking over the chart.

## Controlled before/after measurement

The baseline is production commit `13d51fcfd51cd6809bc75f205d95bdaf4bdc18a6`,
built in a separate clean worktree with only the benchmark fixtures added.
Both versions used an iPhone 17 Pro simulator on iOS 26.2 and the same synthetic
all-ranges response, New York calendar, fixed October 18 clock, and 200 ms
transport delay. Three repetitions were collected per scenario.

After an initial October 18 load, excluded from timing and request counts, each
scenario visits September 2026, October 2026, 2025, 2026, the week containing
October 11, and the week containing October 18, in that order.

| Controller path | Requests before → after | Mean elapsed before → after | Reduction |
| --- | --- | --- | --- |
| Cache selection, then explicit period load on a miss | 6 → 2 | 1,363.5 → 452.6 ms | 66.8% |
| Cache selection, then swipe prefetch/select on a miss | 5 → 2 | 1,152.5 → 454.0 ms | 60.6% |

The revised request counts are asserted by the tests. Timing includes local
response decoding and controller work, but excludes automatic adjacent prefetch,
UIKit gesture dispatch, animation, and real server execution. These are controlled
request-avoidance measurements, not production end-to-end latency claims.

Raw milliseconds, in repetition order:

- Explicit load baseline: 1396.006, 1328.582, 1365.827; revised: 463.129,
  464.146, 430.460.
- Swipe path baseline: 1150.636, 1157.880, 1148.920; revised: 465.687,
  465.660, 430.550.

Reproduce the revised measurement with an available simulator identifier:

```sh
xcodebuild test -project ConvoLab.xcodeproj -scheme ConvoLab \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -only-testing:ConvoLabTests/StudyTimePeriodBenchmarkTests \
  -test-iterations 3 -parallel-testing-enabled NO
```

The benchmark prints `TIME_PERIOD_CACHE_JSON` and attaches JSON to the result
bundle. Native `TimeChartPerformanceUITests` separately cover repeated left/right
swipes, category filters, chart accessibility, and cancellation of an uncached
eight-second request by changing the selected range. The cold fixture starts at a
prior month's boundary so its target is genuinely outside cached monthly coverage.

## Correctness and follow-up scope

Focused tests cover direct and derived cache hits, DST day boundaries, incomplete
coverage, freshness ordering, joined requests, one-consumer cancellation, refresh
failure, account/timezone changes, and rapid failed picker changes returning to an
available chart. Mock transports are reset after every new test to avoid leaking
deferred handlers into unrelated suites.

This change keeps the existing all-ranges API contract. It does not yet add a
bounded persisted period history, age/midnight freshness policy, deeper concurrent
prefetch, or changes to the startup session-download sequence. Those are separate
follow-ups; freshness here remains driven by synchronization and mutation epochs.
