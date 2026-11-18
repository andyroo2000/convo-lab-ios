import { execFileSync } from "node:child_process";
import {
  mkdirSync,
  existsSync,
  readFileSync,
  copyFileSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { patchTypingEngine } from "./patch-typing-engine.mjs";
const root = fileURLToPath(new URL("../", import.meta.url));
const vendor = resolve(root, "TypingEngine/Vendor/AzooKey");
const revision = "80b8204f1cdfb364bb2ed355cf52c7ebb2519a0c";
function run(command, args, cwd = root) {
  execFileSync(command, args, { cwd, stdio: "inherit" });
}
mkdirSync(resolve(root, "TypingEngine/Vendor"), { recursive: true });
if (!existsSync(vendor))
  run("git", [
    "clone",
    "https://github.com/azooKey/AzooKeyKanaKanjiConverter.git",
    vendor,
  ]);
run("git", ["checkout", "--detach", revision], vendor);
run("git", ["submodule", "update", "--init", "--recursive"], vendor);
const api = resolve(vendor, "Sources/KanaKanjiConverterModule/ConverterAPI");
for (const name of ["WholePhraseCandidates", "NeuralBoundaryRanker", "BoundaryScoreCache"])
  copyFileSync(
    resolve(root, `TypingEngine/Adapters/${name}.swift`),
    resolve(api, `ConvoLab${name}.swift`),
  );
mkdirSync(resolve(root, "TypingEngine/Vendor/Personalization"), {
  recursive: true,
});
copyFileSync(
  resolve(root, "TypingEngine/Adapters/Personalization.swift"),
  resolve(root, "TypingEngine/Vendor/Personalization/Personalization.swift"),
);
patchTypingEngine({ root, vendor, revision });
const resources = resolve(
  root,
  "TypingEngine/Sources/PlaygroundEngine/Resources",
);
const model = resolve(resources, "model.gguf");
const hash = "501f605d088f5b988791a00ae19ed46985ed7c48144f364b2f3f1f951c9b2083";
if (!existsSync(model)) {
  const url =
    "https://huggingface.co/Miwa-Keita/zenz-v3-small-gguf/resolve/d48369e21adb9f49903eb7c54be1a1d9723eb805/ggml-model-Q5_K_M.gguf";
  run("curl", ["--fail", "--location", "--retry", "3", "--output", model, url]);
}
if (createHash("sha256").update(readFileSync(model)).digest("hex") !== hash)
  throw Error("Model checksum mismatch");
// Keep exported benchmark identity tied to the checksum actually verified above.
const reportSource = readFileSync(resolve(root, "ConvoLab/TypingPlayground/TypingBenchmarkReport.swift"), "utf8");
if (!reportSource.includes(`modelSHA256 = "${hash}"`))
  throw Error("Benchmark model identity does not match the verified model");
run(
  "npm",
  ["ci", "--no-audit", "--no-fund"],
  resolve(root, "TypingPlaygroundWeb"),
);
run(process.execPath, ["scripts/build-typing-web.mjs"]);
console.log("Pinned native engine, model, and local notebook assets prepared.");
