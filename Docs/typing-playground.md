# iPhone typing playground

Open **Settings → Experiments → Japanese typing playground**. Use an English
keyboard to type romaji directly in the notebook. The bundled AzooKey/Zenzai model
preloads before editing is enabled. Conversion runs on the device, without a
server request or shared learning history. This scratchpad is separate from Journal
and uses a nonpersistent WebView session. Copy anything you want to keep before
closing; scratchpad text is not retained between sessions.

Tap candidates to select alternatives. The bottom controls provide previous/next
section, Shorten/Lengthen boundary adjustment, kana, and Commit. Hardware keyboard
Space, arrows, Shift+Left/Right, Enter and Escape retain the desktop behavior.

## Measurement

Open **Benchmark → Run benchmark**, keep the screen open, then use **Share benchmark
results** to export JSON. It runs the desktop comparison's 24 public phrases three
times and four exhaustive, 160-candidate boundary reranking requests. No notebook
text is exported. The report includes device identifier, OS/app/build, thermal state,
model checksum, preload time, candidates and native/wall durations. Memory footprint
is sampled after preload and each conversion; it is not a continuously observed peak. Ordinary
conversion and boundary ranking are separate samples. Timings exclude keyboard,
WebView bridge and rendering. Use a cool, unplugged phone with Low Power Mode off
for the most comparable run; repeat a run to see thermal/cache effects.

Physical iPhones use Metal with inference limit 1 (normal effort). Simulators use
an explicitly labelled CPU path because this upstream Metal binary cannot load the
model in Simulator. Simulator timings measure the host Mac, not an iPhone.

## Reproducible build

Run `node scripts/prepare-japanese-input.mjs` before opening/building the Xcode
project, including in clean release worktrees. It prepares pinned upstream source,
submodules, the checksum-verified 72 MB model, and the local notebook bundle. These
large/generated files are ignored; authored adapters, fixtures, dependency pins,
web sources and attribution text are tracked. CI runs the preparation step.

Run `swift test --package-path TypingEngine` for request validation and the shared
ConvoLab Xcode scheme for app/UI tests. `TypingPlaygroundUITests` exercises native
conversion and a complete benchmark. The debug-only `typing-playground` UI fixture
opens the experiment without a production login. Release has no fixture bypass.

The engine credits screen includes the unchanged model's CC BY-SA 4.0 attribution
and third-party licenses. Existing signed release automation remains authoritative;
prepare the worktree first and use a strictly increasing, 14-digit UTC build number.
