# iOS sync performance, 17 October 2026

The completed changes reduce median initial sync from **31.63 seconds to 4.76 seconds (84.9%)**, warm sync from **3.18 seconds to 0.70 seconds (78.0%)**, and incremental sync from **3.58 seconds to 0.99 seconds (72.4%)** in the controlled 2,000-card profile. Automatic sync no longer downloads the study window's media, and repeated database scans and JSON decoding have been reduced. Maximum main-actor scheduling gaps improve, but remain about **894 ms cold, 283 ms warm, and 272 ms incremental**; the results do not establish a freeze-free interface.

Automatic sync now updates card metadata without downloading the study window’s audio/images. Existing downloaded media stays available; Settings → Offline → Download Offline Study explicitly prepares the current window. Entering a review still prepares its active media, and Daily Audio retains its existing download-on-generation-completion behavior.

| PR | Change | Commit |
| --- | --- | --- |
| [#271](https://github.com/andyroo2000/convo-lab-ios/pull/271) | Reproducible benchmark and baseline | `d30ef206` |
| [#272](https://github.com/andyroo2000/convo-lab-ios/pull/272) | Separate automatic study sync from offline downloads | `ed0b790` |
| [#273](https://github.com/andyroo2000/convo-lab-ios/pull/273) | Batch database queries during feed commits | `2e689447` |
| [#274](https://github.com/andyroo2000/convo-lab-ios/pull/274) | Coalesce overlapping startup and foreground refreshes | `95ae0b16` |
| Decoded-card cache (this change) | Reuse decoded card values across local reads and reconciliation | Source: `80c4bb7` |

The media-only and feed-only comparisons each change one behavior against the original baseline; their improvements are **not additive**. The media-only profile intentionally finishes without newly downloaded assets. Feed-only retains the original media behavior, requests, bytes, and offline-ready cards, so its cold-sync gain reflects less local processing rather than less completed work. **Pre-cache** measures all four merged PRs together at `95ae0b16`, with source verified against that commit and no cache or no-op write guards. It is the direct comparison for the final cache implementation.

All times are milliseconds: **median (minimum–maximum)** over three repetitions.

| Variant | Phase | Sync elapsed | Maximum main-actor scheduling gap |
| --- | --- | ---: | ---: |
| Baseline | Cold | 31,629.8 (31,398.1–31,988.9) | 1,204.1 (1,194.6–1,226.2) |
| Baseline | Warm | 3,178.7 (3,158.5–3,260.6) | 1,603.0 (1,598.6–1,652.8) |
| Baseline | Delta | 3,581.6 (3,556.9–3,613.2) | 1,629.2 (1,621.8–1,641.8) |
| Media policy alone | Cold | 28,962.5 (28,896.7–29,456.3) | 1,240.9 (1,228.9–1,362.8) |
| Media policy alone | Warm | 2,754.0 (2,752.0–2,774.3) | 1,243.3 (1,237.1–1,254.5) |
| Media policy alone | Delta | 3,078.9 (3,049.1–3,080.4) | 1,246.3 (1,241.8–1,257.9) |
| Feed queries alone | Cold | 8,364.1 (8,354.6–8,375.4) | 922.6 (922.0–926.8) |
| Feed queries alone | Warm | 3,168.4 (3,163.5–3,170.9) | 1,594.3 (1,592.9–1,605.1) |
| Feed queries alone | Delta | 3,536.6 (3,520.8–3,553.4) | 1,617.8 (1,616.3–1,618.6) |
| Pre-cache: first four PRs | Cold | 5,717.2 (5,697.4–5,726.1) | 1,250.1 (1,244.6–1,252.4) |
| Pre-cache: first four PRs | Warm | 2,762.5 (2,749.5–2,772.4) | 1,249.7 (1,244.7–1,253.6) |
| Pre-cache: first four PRs | Delta | 3,042.8 (3,042.5–3,057.4) | 1,249.7 (1,246.6–1,263.1) |
| Final combined | Cold | 4,761.5 (4,717.8–4,798.7) | 894.5 (894.4–897.0) |
| Final combined | Warm | 699.2 (694.2–704.4) | 282.7 (282.5–292.0) |
| Final combined | Delta | 989.5 (988.0–991.9) | 272.3 (270.8–283.4) |

The media-only change reduces median cold/warm/delta sync duration by **8.4% / 13.4% / 14.0%**. Feed-query batching reduces cold duration by **73.6%**; warm/delta results are essentially unchanged (**0.3% / 1.3%** lower). First session visibility during cold sync improves from **27,586.7 ms** at baseline to **4,420.2 ms** in the final implementation. Most of that improvement comes from feed batching: its independent result is **4,366.0 ms**, compared with **27,649.5 ms** for media-only. The final cache does not improve cold first-session visibility versus pre-cache (**4,392.3 ms**).

The final cache change has identical requests and bytes to pre-cache, so its elapsed-time reduction reflects less local work. Percent reductions use the medians, not the fastest repetitions:

| Phase | Elapsed vs baseline | Elapsed vs pre-cache | Maximum gap vs baseline | Maximum gap vs pre-cache |
| --- | ---: | ---: | ---: | ---: |
| Cold | 84.95% | 16.72% | 25.72% | 28.45% |
| Warm | 78.01% | 74.69% | 82.37% | 77.38% |
| Delta | 72.37% | 67.48% | 83.29% | 78.21% |

The p95 scheduling gap also falls substantially versus baseline. Cold p95 is essentially unchanged by the final cache; it primarily reduces the largest cold pause and repeated work in warm/delta sync.

| P95 scheduling gap, ms | Cold | Warm | Delta |
| --- | ---: | ---: | ---: |
| Baseline | 715.4 (713.5–721.7) | 958.0 (945.4–971.5) | 421.2 (419.2–423.4) |
| Pre-cache | 47.4 (46.5–47.8) | 869.7 (856.5–875.8) | 422.3 (420.8–423.3) |
| Final combined | 48.6 (46.4–49.0) | 175.1 (174.9–175.5) | 82.4 (81.2–83.1) |

Same-container account reactivation is measured separately. Its median (range) is **456.2 ms (455.3–478.4)** at baseline, **461.2 ms (459.8–463.8)** with the media policy, and **454.3 ms (453.6–454.9)** with feed batching. The pre-cache combined result is **462.4 ms (458.7–463.8)**. The final combined result is **449.6 ms (449.5–450.0)**, only **1.5% below baseline** and **2.8% below pre-cache**. This remains meaningful synchronous work at activation. Deactivation clears the final decoded-value cache, so this measurement does not assume that cached values survive logout or relaunch.

| Work completed / traffic | Baseline | Media policy alone | Feed queries alone | Pre-cache | Final combined |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cold HTTP requests | 133 | 83 | 133 | 83 | 83 |
| Warm / delta HTTP requests | 4 / 9 | 4 / 9 | 4 / 9 | 4 / 9 | 4 / 9 |
| Cold media requests | 50 | 0 | 50 | 0 | 0 |
| Cold decoded media bytes | 8,192,000 | 0 | 8,192,000 | 0 | 0 |
| Cold response bytes, including JSON/base64 | 12,936,332 | 1,940,782 | 12,936,332 | 1,940,782 | 1,940,782 |
| Downloaded assets / offline-ready cards | 1,000 / 500 | 0 / 0 | 1,000 / 500 | 0 / 0 | 0 / 0 |
| Persisted cards after every phase | 2,000 | 2,000 | 2,000 | 2,000 | 2,000 |

These counts are identical across all three repetitions of each variant. Warm/delta download no new media. Checkpoints reach 2,000 after cold/warm and 2,120 after delta. The benchmark checks card contents, deletion handling, checkpoint advancement, cache files, and that missing media is never advertised as ready offline. The explicit-download regression separately verifies that active and reserve media can still be prepared.

The feed regression enforces one pending-mutation query and one active-count query per nonempty page, including a populated outbox. For this 40-page cold profile, that means **40 instead of 2,000 queries of each kind (98% fewer)**. These are test-backed query bounds, distinct from the HTTP counts above. Alias/deletion ordering, edits between pages, cancellation, rollback, and retained dirty duplicates have focused correctness coverage; the retained-duplicate test confirms that preserved rows become inactive before the next insertion.

A process sample confirmed repeated JSON decoding during local reads, including work that an earlier cache tied to SwiftData model instances did not eliminate. The final implementation keeps **decoded value snapshots in an in-memory cache owned by the repository**, shared with offline reconciliation. Entries are scoped to the account and record ID, and reused only when the exact payload bytes match. Raw writes, rollback, and malformed replacement bytes therefore cannot silently reuse stale values. Full-library reads prune deleted records; account changes, deactivation, and local-data deletion clear the cache. It retains no SwiftData model instances and changes no persisted model or schema. Small write guards also avoid reassigning already-inactive queue flags and already-empty media readiness timestamps.

This cache survives repeated repository reads during an active account session, not process termination. The first decode after launch, deactivation, or a payload change still has a cost; memory usage grows with the active account's decoded library. The final measurements compare this implementation with the uncached `95ae0b16` control. The earlier transient-cache experiment is retained separately and is not used as evidence for the delivered cache.

Startup coalescing addresses duplicate work rather than promising a separate throughput percentage. The integrated fixture sends two startup calls, one foreground callback, and one Study-screen refresh. It observes **one account verification, one capability request, and one Daily Audio request**, with **zero card-feed requests before capabilities finish**. Concurrent callers share app-owned refresh work; account or credential changes cannot join stale work, and a disappearing screen cannot cancel uploads shared by other callers. Existing freshness and retry policies remain in place.

Scheduled iOS background refresh is deliberately deferred. [The lifecycle investigation](../sync-lifecycle.md) explains that iOS chooses execution time and gives short refresh tasks up to 30 seconds, while current shared outbox tasks do not reliably stop when an outer caller is cancelled and some requests can last 45 seconds. Registering them now would risk suspension during uploads. A follow-up needs bounded metadata-only work and expiration tests proving underlying requests stop while checkpoints and pending writes remain durable. Foreground/startup synchronization remains available; no background scheduling guarantee is being made.

The benchmark uses the real API client/decoding, paginated feed application, disk-backed SwiftData, session/reserve reconciliation, and media file writes. A deterministic URLProtocol replaces the server. Each independent repetition starts with a fresh database and cache owner, then runs cold, warm, and delta in that order. The profile has 2,000 cards, 100 active cards, 400 reserve cards, two 8 KiB assets per study-window card, and 20 ms latency per request. Delta contains 100 updates, 10 deletions, and 10 replacements. The normal CI profile uses 150 cards. [Reproduction instructions](README.md) describe the opt-in large run and retained XCTest JSON attachment.

Source provenance: the original production baseline is `4ff481d42f828c5be225355702f7d0ef3f1dec16`, using benchmark revision `ecdd6c8`. The pre-cache control is merged main `95ae0b16ab5e7a147a85a8c2d7272e09afbec94c`. The final measured source is `80c4bb7367bdc8314dadf29d1bb0e231122f3d58`, directly on that control. The same deterministic workload and measurement code were used for every comparison.

Comparisons use Xcode 26.2, an iOS 26.2 simulator, Debug builds, serial repetitions, and no overlapping builds/tests. The earlier exploratory run that overlapped compilation is excluded. The 10 ms main-actor heartbeat measures scheduling delay, **not rendered frames, animation smoothness, or physical-device launch time**. Account reactivation reuses a container and is not a fresh-process cold-cache launch. Assets are opaque 8 KiB payloads, not playable audio/images; latency is synthetic and bandwidth is not simulated. Authentication, capabilities, other startup domains, and large outbound mutation backlogs are outside the timed profile. Three repetitions provide a local comparison, not a statistical guarantee or a forecast for Andrew’s iPhone.

All repetitions are retained below rather than selecting the fastest run. Raw data includes every metric, including heartbeat sample counts, p95 gaps, first-session visibility, activation timing, endpoint counts, and byte totals: [baseline.json](baseline.json), [media-only.json](media-only.json), [feed-only.json](feed-only.json), and [pre-cache.json](pre-cache.json). Final controlled measurements are in [combined.json](combined.json). Earlier [transient-cache-only.json](transient-cache-only.json) and [interim-combined.json](interim-combined.json) are retained as experimental evidence, but do not describe the final cache implementation and are excluded from the main comparison.

| Variant | Phase | Elapsed runs 1 / 2 / 3, ms | Maximum-gap runs 1 / 2 / 3, ms |
| --- | --- | ---: | ---: |
| Baseline | Cold | 31,988.9, 31,629.8, 31,398.1 | 1,226.2, 1,204.1, 1,194.6 |
| Baseline | Warm | 3,260.6, 3,178.7, 3,158.5 | 1,652.8, 1,603.0, 1,598.6 |
| Baseline | Delta | 3,613.2, 3,581.6, 3,556.9 | 1,641.8, 1,629.2, 1,621.8 |
| Media policy alone | Cold | 29,456.3, 28,896.7, 28,962.5 | 1,362.8, 1,228.9, 1,240.9 |
| Media policy alone | Warm | 2,774.3, 2,752.0, 2,754.0 | 1,254.5, 1,243.3, 1,237.1 |
| Media policy alone | Delta | 3,080.4, 3,049.1, 3,078.9 | 1,246.3, 1,241.8, 1,257.9 |
| Feed queries alone | Cold | 8,375.4, 8,364.1, 8,354.6 | 926.8, 922.0, 922.6 |
| Feed queries alone | Warm | 3,168.4, 3,170.9, 3,163.5 | 1,594.3, 1,605.1, 1,592.9 |
| Feed queries alone | Delta | 3,553.4, 3,520.8, 3,536.6 | 1,618.6, 1,616.3, 1,617.8 |
| Pre-cache: first four PRs | Cold | 5,697.4, 5,726.1, 5,717.2 | 1,244.6, 1,250.1, 1,252.4 |
| Pre-cache: first four PRs | Warm | 2,772.4, 2,762.5, 2,749.5 | 1,244.7, 1,249.7, 1,253.6 |
| Pre-cache: first four PRs | Delta | 3,057.4, 3,042.5, 3,042.8 | 1,263.1, 1,249.7, 1,246.6 |
| Final combined | Cold | 4,717.8, 4,798.7, 4,761.5 | 894.5, 894.4, 897.0 |
| Final combined | Warm | 704.4, 699.2, 694.2 | 292.0, 282.7, 282.5 |
| Final combined | Delta | 988.0, 989.5, 991.9 | 272.3, 270.8, 283.4 |

The final combined simulator gate passed **797 XCTest unit tests, 8 Swift Testing tests, and 13 UI tests**. A focused run passed **252 tests**, including **13 cache regressions** covering reuse, payload changes, malformed replacements, rollback, account isolation, pruning, and cache clearing. CodeScene MCP rated all six changed source/test files **10.0** with no findings; both the staged safeguard and branch analysis covered all six and passed.
