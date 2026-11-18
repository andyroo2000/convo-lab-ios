import { InlineSession, kanaComposer } from "./inline-session.mjs";
import { NotebookHistory } from "./history.mjs";
import { LiveComposition } from "./live-composition.mjs";

export class InlineEditor {
  native = false;
  internal = false;
  japanese = true;
  ready = false;

  constructor(elements, toHiragana) {
    this.elements = elements;
    this.field = elements.input;
    this.session = new InlineSession(this.field, kanaComposer(toHiragana), () =>
      this.changed(),
    );
    this.history = new NotebookHistory(this.field, () => this.changed());
    this.live = new LiveComposition(this.session, elements);
    this.listen();
  }

  listen() {
    this.field.addEventListener("beforeinput", (event) =>
      this.beforeInput(event),
    );
    this.field.addEventListener("input", () => this.externalInput());
    this.field.addEventListener("keydown", (event) => this.keydown(event));
    this.field.addEventListener("pointerdown", () => this.finish());
    this.field.addEventListener("blur", () => this.finish());
    this.field.addEventListener("compositionstart", () => {
      this.finish();
      this.native = true;
    });
    this.field.addEventListener("compositionend", () => {
      this.native = false;
      this.history.remember();
    });
  }

  changed() {
    this.internal = true;
    this.field.dispatchEvent(new Event("input", { bubbles: true }));
    this.internal = false;
  }

  externalInput() {
    if (this.internal) return;
    this.session.active = null;
    this.live.reset();
    if (!this.native) this.history.remember();
  }

  setReady(ready) {
    this.ready = ready;
    if (!ready) this.finish();
    this.field.readOnly = !ready;
  }

  finish(preserveSelection = false) {
    this.session.finish(preserveSelection);
    this.live.reset();
    this.history.remember();
    this.elements.status.textContent =
      "Type in the notebook · Conversion appears as you pause · Enter to commit.";
  }

  toggleMode() {
    this.finish();
    this.japanese = !this.japanese;
    this.field.focus();
    return this.japanese;
  }

  reconcileCaret() {
    if (!this.session.active || this.session.atCaret()) return;
    // A selection made by assistive technology or script must never be replaced
    // using the previous composition's offsets.
    this.session.active = null;
    this.live.reset();
    this.history.remember();
  }

  beforeInput(event) {
    if (this.native || event.isComposing) return;
    if (event.inputType.startsWith("history")) {
      event.preventDefault();
      this.undo(event.inputType === "historyRedo");
      return;
    }
    this.reconcileCaret();
    if (this.handleSoftwareKey(event)) return;
    if (this.handleRomanInput(event)) return;
    if (this.handlePunctuation(event)) return;
    if (event.inputType === "deleteContentBackward" && this.session.active) {
      event.preventDefault();
      this.live.reset();
      this.session.backspace();
      this.live.typed();
      return;
    }
    this.finish(this.field.selectionStart !== this.field.selectionEnd);
  }

  handleSoftwareKey(event) {
    if (!this.japanese || !this.session.active) return false;
    const key = event.inputType === "insertText" && event.data === " "
      ? " " : ["insertLineBreak", "insertParagraph"].includes(event.inputType) ? "Enter" : null;
    if (!key || !this.compositionKey({ key })) return false;
    event.preventDefault();
    return true;
  }

  handlePunctuation(event) {
    if (!this.japanese || event.inputType !== "insertText") return false;
    const text = { ".": "。", ",": "、", "?": "？", "!": "！", "/": "・" }[
      event.data
    ];
    if (!text) return false;
    event.preventDefault();
    this.finish();
    this.insertLiteral(text);
    return true;
  }

  handleRomanInput(event) {
    if (!this.japanese || event.inputType !== "insertText") return false;
    if (!/^[a-z'-]+$/i.test(event.data ?? "")) return false;
    event.preventDefault();
    if (!this.session.active) this.history.remember();
    this.session.append(event.data);
    this.live.typed();
    this.elements.status.textContent =
      "Live conversion · Enter to commit · Space or arrows for choices.";
    return true;
  }

  convert() {
    if (!this.ready || this.native) return false;
    this.reconcileCaret();
    if (!this.session.active && !this.selectedKana()) return false;
    this.live.convert();
    return true;
  }

  selectedKana() {
    const text = this.field.value.slice(
      this.field.selectionStart,
      this.field.selectionEnd,
    );
    if (!/^[\p{Script=Hiragana}\p{Script=Katakana}ー。、！？・]+$/u.test(text))
      return false;
    this.history.remember();
    this.session.begin(text);
    return true;
  }

  escape() {
    if (this.session.active?.preview) {
      this.live.reset();
      this.session.restore();
      this.live.paint();
    } else this.finish();
  }

  undo(redo) {
    this.finish();
    this.history.move(redo);
  }

  keydown(event) {
    if (this.nativeKey(event)) return;
    if (this.historyKey(event)) return;
    if ([event.metaKey, event.ctrlKey, event.altKey].some(Boolean)) return;
    this.reconcileCaret();
    if (this.compositionKey(event)) event.preventDefault();
    else if (
      [
        "ArrowLeft",
        "ArrowRight",
        "ArrowUp",
        "ArrowDown",
        "Home",
        "End",
        "Tab",
        "Delete",
      ].includes(event.key)
    )
      this.finish();
  }

  nativeKey(event) {
    return [this.native, event.isComposing, event.keyCode === 229].some(
      Boolean,
    );
  }

  historyKey(event) {
    if (!(event.metaKey || event.ctrlKey)) return false;
    const key = event.key.toLowerCase();
    if (!["z", "y"].includes(key)) return false;
    event.preventDefault();
    this.undo(key === "y" || event.shiftKey);
    return true;
  }

  compositionKey(event) {
    if (event.key === " " && this.japanese) return this.convert();
    if (!this.session.active) return false;
    const actions = { Enter: () => this.finish(), Escape: () => this.escape() };
    if (actions[event.key]) {
      actions[event.key]();
      return true;
    }
    if (["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(event.key))
      return this.live.arrow(event.key, event.shiftKey);
    return false;
  }

  insertExample(reading) {
    this.finish();
    this.field.focus();
    this.history.remember();
    this.session.begin();
    this.session.append(reading);
    this.convert();
  }

  newline() {
    this.finish();
    this.insertLiteral("\n");
    this.field.focus();
  }

  insertLiteral(text) {
    this.field.setRangeText(
      text,
      this.field.selectionStart,
      this.field.selectionEnd,
      "end",
    );
    this.changed();
    this.history.remember();
  }
}
