# Responsive Time history imports

The 2,631-row cold-history workload reduced its median longest main-actor scheduling gap from **486.82 ms to 21.53 ms (95.6% lower)**. All three revised cold runs had no gaps above 50 ms. Cold full synchronization fell from 2204.34 ms to 2014.30 ms (8.6% lower).

Cached startup still has a synchronous activation cost: the median longest gap is **104.28 ms**, down from 155.22 ms. Gaps above 50 ms fell from three to one per run. Cached full synchronization improved 4.0%, and fresh chart data became available 12.2% sooner. This is not a claim that every startup pause is eliminated.

## Production change

History now commits in batches of 128 and yields only with a clean context. Every boundary checks cancellation, account activation, token and local mutation ownership. Pending rows and tombstones remain authoritative. A failed batch rolls back only its own work; earlier committed batches remain durable and an ordinary retry converges.

The final projection pages by client identifier using the existing unique `(userID, clientSessionID)` index. An explicit lexical comparator keeps sorting and page boundaries consistent on disk and in memory. The resulting value types are sorted once by descending date and identifier in a detached task; ownership is checked again before publication. The newest active timer is selected across all identifier pages. No model or database schema change is required.

The unused remote-result projection and the redundant full local reload after upload acknowledgement are removed. Upload acknowledgement changes sync bookkeeping and calendar identifiers; the already displayed session and active-timer values remain valid.

## Primary measurements

Three independent cold/cached pairs per version. All durations include activation. Values are median (minimum–maximum), in milliseconds.

| Scenario / metric | Previous PR | Final change | Change |
|---|---:|---:|---:|
| cold / activation | 3.32 (2.05–6.47) | 2.11 (2.05–3.41) | -36.6% |
| cold / first visible chart data | 399.15 (395.48–433.62) | 406.07 (395.47–429.58) | +1.7% |
| cold / first fresh chart data | 399.15 (395.48–433.62) | 406.07 (395.47–429.58) | +1.7% |
| cold / full sync | 2204.34 (2190.58–2205.49) | 2014.30 (2004.61–2029.35) | -8.6% |
| cold / longest scheduling gap | 486.82 (477.51–492.90) | 21.53 (21.21–21.96) | -95.6% |
| cold / p95 scheduling gap | 12.12 (12.12–12.15) | 15.73 (14.73–16.55) | +29.7% |
| cached / activation | 104.11 (103.79–106.50) | 104.27 (104.08–107.24) | +0.2% |
| cached / first visible chart data | 104.12 (103.80–106.51) | 104.28 (104.09–107.25) | +0.2% |
| cached / first fresh chart data | 579.62 (576.77–586.64) | 508.62 (503.57–515.57) | -12.2% |
| cached / full sync | 2048.71 (2041.37–2063.71) | 1966.76 (1961.37–2099.17) | -4.0% |
| cached / longest scheduling gap | 155.22 (151.06–156.62) | 104.28 (104.09–107.25) | -32.8% |
| cached / p95 scheduling gap | 12.20 (12.11–12.26) | 12.97 (12.78–14.11) | +6.3% |

Gaps above 50 ms, by repetition: cold **[1, 1, 1] → [0, 0, 0]**; cached **[3, 3, 3] → [1, 1, 1]**. Cold p95 rises because the same work is distributed across short batches instead of concentrated in one very long pause. Evaluate it alongside the maximum and pause counts. Cold first-fresh chart time increased about 1.7% in these runs; no cold chart-readiness improvement is claimed.

Both versions make exactly three requests with peak concurrency two, upload 6,929 body bytes, receive 750,126 body bytes, and cancel none. Every run verifies exact full-record equality for all 2,661 persisted sessions, all 30 acknowledgements, no remaining pending rows, fresh chart totals, and analytics starting after the upload barrier.

## Separate 20,000-row stress check

One cold/cached pair per version; these individual observations are not pooled with the primary three-repeat results. Both versions preserve all 20,030 records and acknowledge the same 30 pending uploads.

| Scenario / metric | Previous PR, ms | Final change, ms |
|---|---:|---:|
| cold / activation | 5.78 | 4.56 |
| cold / first visible chart data | 437.86 | 435.96 |
| cold / first fresh chart data | 437.86 | 435.96 |
| cold / full sync | 16755.72 | 5935.17 |
| cold / longest scheduling gap | 13017.99 | 27.38 |
| cold / p95 scheduling gap | 11.15 | 21.13 |
| cached / activation | 842.57 | 847.62 |
| cached / first visible chart data | 842.59 | 847.64 |
| cached / first fresh chart data | 1813.20 | 1337.69 |
| cached / full sync | 6273.06 | 5954.13 |
| cached / longest scheduling gap | 1155.82 | 847.64 |
| cached / p95 scheduling gap | 11.22 | 14.04 |

Stress gaps above 50 ms fell from one to zero cold and from four to two cached. The remaining cached maximum is approximately 848 ms during synchronous activation; large cached histories are not freeze-free.

The first batching candidate reduced cold stalls but regressed cached stress full sync by 57%. A separate sampled-stack diagnostic attributed most additional work to repeated sorted projection fetches. Read-only SQLite EXPLAIN showed a temporary B-tree sort for that query. The final client-ID keyset query uses the existing unique index for both the user and identifier bound, with no temporary sort. Cached stress full sync now improves from 6,273.06 to 5,954.13 ms.

A compound-index candidate was also measured, then rejected because an authentic prior iOS database did not acquire the new index merely by reopening with a changed declaration. The final implementation uses the index already present on existing installations. All candidate results, migration investigation, profiles and query plans are retained; only the final compatible implementation appears in these tables. Profile runs are excluded from timing comparisons.
## Method and limits

Baseline products were built from `0ce765fa9bfbb87c2cd26d760655f86fe4f66c77`, whose source tree is identical to merged PR #282 (`d0c8402e914fdaf12f2d94f67939256538c1f837`). Use that merged commit to reproduce the baseline. Both sides use identical startup fixture bytes, Debug builds with normal simulator signing, and iOS 26.2 on simulator `82E783C8-3CFD-404D-8B51-710F0526AF57`. No other builds or tests ran during controlled measurements. Earlier unsigned PR6 numbers are archived and excluded from this comparison.

The fixture uses the real API client and decoder, an isolated disk-backed SwiftData store, and an isolated persisted analytics cache. History spans 90 days inside the requested replica window. Transport delays are controlled at 150 ms for uploads, 1,200 ms for history, and 200 ms for analytics. They isolate local work and request ordering; these results are not a production network SLA.

The internal 10 ms heartbeat records main-actor scheduling gaps without publishing observable state. It does not measure rendered frames. First-visible and first-fresh durations measure chart model availability, not frame completion. The probe begins before activation, and its initial gap includes activation. Request timestamps use a separate fixture-construction epoch and are compared only for ordering and duration. Cached fixtures seed history and a readable prior analytics snapshot before measurement.

## Reproduction

Use normal simulator signing when building test products; disabling signing invalidates unrelated Keychain tests in the full scheme. Build a separate DerivedData directory for each version, and keep the same simulator and fixture files:

```sh
xcodebuild build-for-testing \
  -project ConvoLab.xcodeproj -scheme ConvoLab \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -derivedDataPath <derived-data> -parallel-testing-enabled NO
```

Copy the generated `.xctestrun` beside the original under `Build/Products`. In every test-bundle dictionary (one containing `TestBundlePath`), set `EnvironmentVariables.TIME_STARTUP_LARGE` to `1`. Keeping the copy beside the original preserves `__TESTROOT__` paths. Do not assume a shell environment variable is forwarded to the simulator. Run the copy:

```sh
xcodebuild test-without-building \
  -xctestrun <derived-data>/Build/Products/TimeHistoryLarge.xctestrun \
  -destination 'platform=iOS Simulator,id=<simulator-id>' \
  -parallel-testing-enabled NO \
  -only-testing:ConvoLabTests/StudyTimeStartupBenchmarkTests
```

The test itself performs three cold/cached pairs; do not add `-test-iterations 3`. For the separate stress copy, additionally set `TIME_STARTUP_HISTORY_COUNT=20000` and `TIME_STARTUP_ITERATIONS=1` in those test environment dictionaries. Ordinary CI uses 120 history rows, three pending completions and shorter delays, with correctness assertions but no timing thresholds.

Logs emit `TIME_STARTUP_JSON`, also attached to result bundles as `time-startup.json`. The external artifact directory is `/Users/andrewlandry/.codex/artifacts/time-analytics-series-20261019/ios-history`. It contains `baseline.json`, `revised.json`, `baseline-stress.json`, `revised-stress.json`, exact `comparison.json`, source/fixture hashes in `provenance.json`, query-plan evidence, all result bundles, and superseded/diagnostic runs. These are local artifacts, not relative repository links.

Deterministic tests cover partial save failure and idempotent retry, dirty-context ownership, pending/tombstone preservation, local edits and deletion between chunks, account reactivation, cancellation, equal-date paging, active-timer selection, and upload acknowledgement with or without a later history failure. The focused gate passed **96 tests**, including all 17 new importer cases and two upload-presentation cases. Variable-width, mixed-case IDs are checked on disk and in memory, and stale ownership after the detached sort is rejected. The full signed repository gate is recorded separately from timing runs.
