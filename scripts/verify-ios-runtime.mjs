import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Xcode's test runner supplies framework search paths that TestFlight does not.
// Inspect the packaged executable, not build settings or the simulator process.
export function verifyRuntimeFrameworks(appPath) {
  const executable = execFileSync(
    "/usr/libexec/PlistBuddy",
    ["-c", "Print :CFBundleExecutable", join(appPath, "Info.plist")],
    { encoding: "utf8" },
  ).trim();
  const binary = join(appPath, executable);
  const dependencies = execFileSync("/usr/bin/otool", ["-L", binary], {
    encoding: "utf8",
  });
  const frameworks = [...dependencies.matchAll(/^\s+@rpath\/(\S+\.framework\/\S+)/gm)]
    .map((match) => match[1]);
  if (frameworks.length === 0) return;

  const commands = execFileSync("/usr/bin/otool", ["-l", binary], {
    encoding: "utf8",
  });
  const hasFrameworkPath = /cmd LC_RPATH\s+cmdsize \d+\s+path @executable_path\/Frameworks \(offset \d+\)/
    .test(commands);
  if (!hasFrameworkPath) {
    throw new Error("Missing LC_RPATH @executable_path/Frameworks; the app would crash at launch.");
  }
  for (const framework of frameworks) {
    if (!existsSync(join(appPath, "Frameworks", framework))) {
      throw new Error(`Missing embedded runtime framework: ${framework}`);
    }
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (!process.argv[2]) throw new Error("Usage: node scripts/verify-ios-runtime.mjs <app bundle>");
  verifyRuntimeFrameworks(resolve(process.argv[2]));
  console.log("Embedded framework runtime paths verified.");
}
