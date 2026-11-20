# Native typing latency

The model, inference limit (1), dictionary, full-phrase prompts, candidate
generation and 160-candidate boundary limit are unchanged.

## What is reused

- Ordinary and boundary conversion share one loaded model. The boundary scorer
  retains its owner, and frees its separate inference context before releasing
  that owner. All access remains inside the app's serial engine actor.
- Normal typing becomes ready after its own model warmup. Additional boundary
  ranking buffers are allocated on the first section adjustment; its measured
  latency includes that setup. They remain ready for subsequent adjustments.
- Starting a phrase clears KV and prefix state instead of recreating the ordinary
  inference context and its buffers. Learning remains disabled.
- Boundary moves reuse the ordinary neural proposal for the exact same reading.
  A changed reading replaces that proposal.
- Full-sentence scores are cached for the current reading only, with at most 512
  outputs retained. Caches live in memory and disappear with the engine.

## Full neural scoring

Metal decodes the common reading prompt once, keeping its KV rows in a
prompt-only sequence. Up to 16 candidates share those rows while retaining
independent suffix attention. The context has 17 sequence IDs and a 512-token
**total** KV pool. Between chunks only candidate suffixes are discarded; a new
scoring request clears the entire pool. Identical prompt tokens are validated
before reuse.

The final prompt logits score each candidate's first continuation token. Suffix
logits score every remaining token, including EOS, without feeding EOS itself
back through the model. Empty continuations use the saved prompt logits without
an empty decode. Every output token is still normalized across the entire
vocabulary using upstream's accumulation order.

Longer sentences cause smaller batches, not shorter context. Inputs exceeding
the pinned upstream capacity of 512 tokens fail explicitly. The old scalar path
also allocates a 512-token batch and context, so falling back to it would not
safely support those oversized sequences.

The 512-token KV pool is shared across sequences, not allocated 16 times. The
pinned llama.cpp version uses the printed `n_ctx_per_seq` value for diagnostics;
attention and KV admission use the actual sequence positions and total pool.
Long-sentence parity tests cover sequences exceeding that printed share.

Simulator / explicitly CPU-only builds retain upstream's scalar scoring. CPU
quantized matrix kernels showed batch-shape-dependent score differences, so this
path deliberately does not use the Metal batching optimization.

## Verification

```sh
node scripts/prepare-japanese-input.mjs
swift test -c release --package-path TypingEngine
swift test -c release -Xswiftc -DZenzaiCPU --package-path TypingEngine
TYPING_LATENCY_REPORT=/tmp/typing-latency.json \
  swift test -c release --package-path TypingEngine --filter TypingLatencyTests
```

Tests compare all 160 scores in four boundary cases with upstream full-sentence
evaluation (0.01 absolute tolerance, unchanged best choice), check long sentences
across batch splits, verify empty continuations, invalid prompt rejection, recovery, cache invalidation/eviction, and compare every ordinary
fixture's complete candidates and section data against recreating the context.
The GPU-specific score/batch checks skip on CPU builds, which call the
unchanged upstream scorer directly. CPU CI checks session reset and cache safety;
the simulator UI benchmark separately exercises all four complete candidate lists.

The opt-in timing run and in-app benchmark perform three 24-phrase passes, then
four boundary cases, each immediately repeated. Repeated timings intentionally
measure score reuse; first-use and repeated results must be reported separately.
Reports include dictionary, model/ordinary warmup and first-use boundary warmup
timings. Preload measures readiness for ordinary neural typing. The benchmark
excludes keyboard events, WebView transport and painting.

Mac Metal and simulator CPU results are development measurements, not iPhone
performance claims. Use the TestFlight report to verify actual device latency,
memory and thermal state after this change.

## Shared-context experiment

The opt-in corpus export runs all 24 fixture phrases three times. Before each
boundary request it performs an ordinary conversion, then moves the first
section boundary one character left (or right if that section has one
character). Every intervening reading invalidates the score cache. Exported
candidates retain scores, sections and dictionary units for full-list comparison.

```sh
BOUNDARY_CORPUS_REPORT=/tmp/boundary-corpus.json \
  swift test -c release --package-path TypingEngine --filter BoundaryCorpusTests
```

### Measured 2026-11-19

Apple M3 (24 GB), Xcode 26.3 Release, native Metal, pinned llama b4846 and the
unchanged zenz-v3 Q5_K_M model. Baseline: `e20a577`. These are Mac measurements of
the iOS engine, **not iPhone timings**. TestFlight's existing benchmark export
remains available for device confirmation. Runs were sequential on the same
machine; no simultaneous GPU benchmarks. Ordinary/cached timings fluctuate with
warmup and system load and are not attributed to this change.

| Work | Before | Shared prompt |
| --- | ---: | ---: |
| Fresh boundary corpus median (24 phrases × 3 passes) | 607 ms | 236 ms |
| はしでたべました / cut 1 (original benchmark) | 627 ms | 266 ms |
| きょうはいいてんきです / cut 3 | 606 ms | 245 ms |
| かみをきりました / cut 2 | 492 ms | 205 ms |
| Longest fixture / cut 7 (first corpus pass) | 1,310 ms | 570 ms |

All 72 ordinary ordered candidate lists were identical. All 72 boundary corpus
requests retained the exact candidate sets, per-candidate dictionary units and
sections, and ordered top five choices. Twenty-one fixtures produce 160
candidates; the other three naturally produce 68, 80 and 128 in both builds.
Full ordering was identical in 48/72 requests; near-ties below the top five
changed order in eight phrases. Maximum absolute score difference was 0.006653.
The existing full-vocabulary reference checks still pass their unchanged 0.01
absolute tolerance, including long sentences spanning multiple batches.

`Benchmarks/shared-context-*.json.gz` contain the losslessly compressed raw
exports, including all candidates, scores and boundary positions. The summary
JSON lists the first pass of each phrase and aggregate quality checks. The
ordinary latency export also includes the same-reading second boundary move;
that case benefits from partial score reuse and is not counted as a fresh phrase.
