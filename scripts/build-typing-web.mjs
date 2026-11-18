import { mkdirSync, readFileSync, writeFileSync, copyFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
const root = fileURLToPath(new URL("../", import.meta.url));
const { build } = await import(
  root + "TypingPlaygroundWeb/node_modules/esbuild/lib/main.js"
);
const target = root + "ConvoLab/TypingPlayground/Generated/";
mkdirSync(target, { recursive: true });
await build({
  entryPoints: [root + "TypingPlaygroundWeb/app.mjs"],
  bundle: true,
  format: "iife",
  outfile: target + "typing-playground.js",
  target: "safari18",
});
const html = readFileSync(
  root + "TypingPlaygroundWeb/index.html",
  "utf8",
).replace(
  "<title>",
  "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'none'\"><title>",
);
writeFileSync(target + "typing-playground.html", html);
copyFileSync(
  root + "TypingPlaygroundWeb/style.css",
  target + "typing-playground.css",
);
copyFileSync(
  root + "TypingPlaygroundWeb/typing-tutor.webp",
  target + "typing-tutor.webp",
);
