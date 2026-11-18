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

Metal evaluates up to 16 independent sentences together, capped at 512 **total**
tokens per decode. Each sentence includes the complete reading, output and EOS.
Sequence IDs isolate attention; the KV pool is cleared between batches. Longer
sentences cause smaller batches, not shorter context. Every output token is still
normalized across the entire vocabulary using upstream's accumulation order.
Inputs exceeding the pinned upstream context/batch capacity of 512 tokens fail
explicitly. The old scalar path also allocates a 512-token batch and context, so
falling back to it would not safely support those oversized sequences.

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
across batch splits, verify cache invalidation/eviction, and compare every ordinary
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
