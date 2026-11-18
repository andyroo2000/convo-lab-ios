import { toHiragana } from "wanakana";
import { attachNotebook, restoreLegacyPhrase } from "./editor.mjs";
import { InlineEditor } from "./inline-editor.mjs";
import { watchReadiness } from "./readiness.mjs";

const byId = (id) => document.getElementById(id);
const notebook = byId("notebook");
const status = byId("status");
const say = (message) => {
  status.textContent = message;
};
attachNotebook(notebook, say);
const editor = new InlineEditor(
  {
    input: notebook,
    status,
    list: byId("candidates"),
    convert: byId("convert"),
    metrics: byId("metrics"),
  },
  toHiragana,
);
watchReadiness((state) => editor.setReady(state === "ready"));

byId("composition").addEventListener("pointerdown", (event) => {
  if (event.target.closest("button")) event.preventDefault();
});
byId("convert").addEventListener("click", () => {
  editor.convert();
  notebook.focus();
});
byId("keep-kana").addEventListener("click", () => {
  editor.session.restore();
  editor.finish();
  notebook.focus();
});
byId("mode").addEventListener("click", (event) => {
  const japanese = editor.toggleMode();
  event.currentTarget.textContent = japanese ? "日本語" : "ABC";
  event.currentTarget.setAttribute("aria-pressed", String(japanese));
});
byId("newline").addEventListener("click", () => editor.newline());
byId("copy").addEventListener("click", async () => {
  editor.finish();
  try {
    await navigator.clipboard.writeText(notebook.value);
    say("Notebook copied.");
  } catch {
    say("Select the notebook text and copy it with your keyboard.");
  }
});
document.querySelectorAll("[data-reading]").forEach((button) => {
  button.addEventListener("click", () =>
    editor.insertExample(button.dataset.reading),
  );
});
restoreLegacyPhrase(byId("restore-phrase"), (text) =>
  editor.insertExample(text),
);

// Touch equivalents of the hardware keyboard's section and commit keys.
document.querySelectorAll("[data-key]").forEach((button) => {
  button.addEventListener("click", () => {
    editor.compositionKey({
      key: button.dataset.key,
      shiftKey: button.dataset.shift === "true",
    });
    notebook.focus();
  });
});
