import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

export function patchTypingEngine({ root, vendor, revision }) {
  const directory = "Sources/KanaKanjiConverterModule/ConversionAlgorithms/Zenzai/Zenz";
  const original = (name) => execFileSync("git", ["show", `${revision}:${directory}/${name}.swift`], {
    cwd: vendor, encoding: "utf8",
  });
  // Physical devices retain Metal; only the simulator needs the CPU backend.
  const context = original("ZenzContext")
    .replaceAll("#if ZenzaiCPU", "#if ZenzaiCPU || targetEnvironment(simulator)")
    .replace("model_params.split_mode = LLAMA_SPLIT_MODE_NONE", "model_params.split_mode = LLAMA_SPLIT_MODE_LAYER");
  const scoring = readFileSync(resolve(root, "TypingEngine/Adapters/BoundaryBatchScoring.swift"), "utf8");
  writeFileSync(resolve(vendor, directory, "ZenzContext.swift"), `${context}\n${scoring}`);
  // Internal access only: the serial boundary ranker shares this model instead
  // of loading a second copy. Ordinary requests still reset the context first.
  const zenz = original("Zenz");
  const declaration = "private var zenzContext: ZenzContext?";
  if (!zenz.includes(declaration)) throw Error("Pinned Zenz context declaration changed");
  const reset = "try? self.zenzContext?.reset_context()";
  if (!zenz.includes(reset)) throw Error("Pinned Zenz session reset changed");
  writeFileSync(resolve(vendor, directory, "Zenz.swift"), zenz
    .replace(declaration, "var zenzContext: ZenzContext?")
    .replace(reset, "self.zenzContext?.resetForTyping()"));
}
