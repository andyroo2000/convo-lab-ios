import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { verifyRuntimeFrameworks } from "./verify-ios-runtime.mjs";

const root = mkdtempSync(join(tmpdir(), "convolab-runtime-test-"));
after(() => rmSync(root, { recursive: true, force: true }));

function buildApp(name, includeRuntimePath) {
  const app = join(root, `${name}.app`);
  const framework = join(app, "Frameworks", "Example.framework", "Example");
  mkdirSync(join(app, "Frameworks", "Example.framework"), { recursive: true });
  writeFileSync(join(app, "Info.plist"), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fixture</string></dict></plist>`);
  writeFileSync(join(app, "library.c"), "int example(void) { return 0; }");
  writeFileSync(join(app, "main.c"), "int example(void); int main(void) { return example(); }");
  execFileSync("xcrun", ["clang", "-dynamiclib", join(app, "library.c"), "-o", framework,
    "-install_name", "@rpath/Example.framework/Example"]);
  const runtimeFlags = includeRuntimePath ? ["-Wl,-rpath,@executable_path/Frameworks"] : [];
  execFileSync("xcrun", ["clang", join(app, "main.c"), framework, "-o", join(app, "Fixture"), ...runtimeFlags]);
  return { app, framework };
}

test("rejects a real linked app with its framework embedded but no runtime path", () => {
  const { app } = buildApp("MissingPath", false);
  assert.throws(() => verifyRuntimeFrameworks(app), /Missing LC_RPATH/);
});

test("accepts a linked app that can launch using its embedded framework", () => {
  const { app } = buildApp("Valid", true);
  assert.doesNotThrow(() => verifyRuntimeFrameworks(app));
  execFileSync(join(app, "Fixture"));
});

test("rejects a runtime path whose required framework is absent", () => {
  const { app, framework } = buildApp("MissingFramework", true);
  rmSync(framework);
  assert.throws(() => verifyRuntimeFrameworks(app), /Missing embedded runtime framework/);
});
