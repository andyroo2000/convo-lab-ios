# Sync performance measurements

`SyncPerformanceTests.testSyncEndToEndPerformanceAndCorrectness` exercises the real
study sync path: APIClient decoding, paged feed application, disk-backed SwiftData,
review-session and offline-reserve reconciliation, and media file writes. A local
URLProtocol replaces the server with deterministic responses and latency. No live
account data or production writes are involved.

The normal test suite uses 150 cards. The large profile uses 2,000 cards, 100 active
review cards, 400 reserve cards, and two 8 KiB assets per card in the study window.
Every request incurs 20 ms of simulated latency. Media sizes are a conservative
lower bound, not a model of full production audio/image sizes or network bandwidth.

Each repetition gets an independent database and cache ownership. It measures:

- Cold sync into an empty database.
- Warm sync after the checkpoint is current.
- Incremental sync with 100 updates, 10 deletions, and 10 replacements.
- Cached-account reactivation separately from network synchronization.
- Total elapsed time, first session visibility, request counts, response/media
  bytes, and main-actor scheduling gaps sampled about every 10 ms.

Assertions verify persisted card content, deletion handling, checkpoint advancement,
cache files, and offline readiness. Timing is recorded rather than asserted against
machine-dependent limits. These are Debug simulator measurements of the sync path,
not physical-device launch timings or rendering/frame-time measurements. Auth,
capabilities, other concurrently refreshed app domains, and large outbound mutation
backlogs are outside this profile and have separate correctness coverage.

## Reproduce

Build for testing using the shared ConvoLab scheme and a fixed simulator:

```sh
xcodebuild build-for-testing -project ConvoLab.xcodeproj -scheme ConvoLab \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath /tmp/convolab-sync-performance-build
```

Copy the generated `.xctestrun` file **within its Build/Products directory** so its
relative test-host paths remain valid. In the copy, add these strings to the
`ConvoLabTests.EnvironmentVariables` dictionary (for newer test-run formats, the
corresponding ConvoLabTests target inside TestConfigurations):

```text
SYNC_PERFORMANCE_LARGE = 1
SYNC_PERFORMANCE_ITERATIONS = 3
```

Run only the benchmark, serially:

```sh
xcodebuild test-without-building -xctestrun <COPIED_XCTESTRUN> \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -only-testing:ConvoLabTests/SyncPerformanceTests \
  -parallel-testing-enabled NO -resultBundlePath /tmp/sync-measurement.xcresult
```

Use the same simulator, Xcode, build configuration, workload, and idle host for every
comparison. Do not run compilers or other tests concurrently. Keep all repetitions
and report medians and ranges. The test prints `SYNC_PERFORMANCE_JSON` and retains
`sync-performance-metrics.json` as an XCTest attachment in the result bundle.

## Baseline: 2026-10-17

Production source: `4ff481d42f828c5be225355702f7d0ef3f1dec16`; benchmark revision:
`ecdd6c8`. Xcode 26.2, iOS 26.2 simulator, Debug, three serial repetitions with no
concurrent builds/tests. Raw measurements: [baseline.json](baseline.json).

| Metric (median; range) | Cold | Warm | Delta |
| --- | --- | --- | --- |
| Sync elapsed, ms | 31,629.8; 31,398.1–31,988.9 | 3,178.7; 3,158.5–3,260.6 | 3,581.6; 3,556.9–3,613.2 |
| Maximum main-actor gap, ms | 1,204.1; 1,194.6–1,226.2 | 1,603.0; 1,598.6–1,652.8 | 1,629.2; 1,621.8–1,641.8 |
| HTTP requests | 133 | 4 | 9 |
| Decoded media bytes downloaded | 8,192,000 | 0 | 0 |

An earlier exploratory run overlapped another compiler job and is excluded from
this baseline. Cached activation is a same-container deactivate/reactivate path;
it is not a fresh-process cold SQLite launch. Media payloads are opaque bytes for
transfer/persistence testing, not playable assets or a rendering workload.
