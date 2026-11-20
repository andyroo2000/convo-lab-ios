import { InlineSession, kanaComposer } from './inline-session.mjs';
import { replaceCompositionRange, changedRange } from './composition-edit.mjs';
import { phraseSections, expandSectionChoices } from './sections.mjs';
import { resizedSections, resolveBoundaries } from './section-boundaries.mjs';

// A synchronous composition model for UITextView. Only explicit choices change
// kana into kanji; inference responses never modify the document or its caret.
export class JournalNativeSession {
  constructor(toHiragana) {
    this.field = new NativeText();
    this.session = new InlineSession(this.field, kanaComposer(toHiragana), () => {});
    this.resetCandidates();
  }

  resetCandidates() {
    this.candidates = [];
    this.sections = [];
    this.selected = -1;
    this.boundaries = [];
    this.manualSections = false;
  }

  external(text) {
    this.session.active = null;
    this.field.value = text;
    this.field.setSelectionRange(Math.min(this.field.selectionStart, text.length), Math.min(this.field.selectionEnd, text.length));
    this.resetCandidates();
    return this.snapshot();
  }

  edit({ text, range, replacement, selection, literal = false }) {
    if (text !== this.field.value) this.external(text);
    this.field.setSelectionRange(selection[0], selection[0] + selection[1]);
    const active = this.session.active;
    if (active && !this.selectionInside(active, range[0], range[1])) this.session.finish(true);
    this.resetCandidates();
    if (literal) this.literal(range[0], range[1], replacement, false);
    else this.replaceInput(range, replacement);
    if (this.session.active?.raw === '') this.session.finish();
    return this.snapshot();
  }

  reconcile(text, selection) {
    const change = changedRange(this.field.value, text);
    this.edit({ text: this.field.value, ...change, selection: change.range, literal: change.replacement.length > 1 });
    return this.moveSelection(selection);
  }

  moveSelection([start, length]) {
    this.field.setSelectionRange(start, start + length);
    const active = this.session.active;
    if (active && !this.selectionInside(active, start, length)) {
      this.session.finish(true);
      this.resetCandidates();
    }
    return this.snapshot();
  }

  selectionInside(active, start, length) {
    return start >= active.start && start + length <= active.end;
  }

  replaceInput([start, length], replacement) {
    const punctuation = { '。': '.', '、': ',', '？': '?', '！': '!', '・': '/', 'ー': '-' };
    const input = punctuation[replacement] ?? replacement;
    if (/^[a-z0-9'.,?!/-]+$/i.test(input)) {
      const active = this.session.active;
      if (active && (start !== active.end || length)) return replaceCompositionRange(this.session, start, length, input);
      return this.session.append(input);
    }
    if (replacement === '\n' && this.session.active) return this.session.finish();
    const active = this.session.active;
    if (!replacement && active) {
      if (start + length === active.end && length === 1) return this.backspace();
      return replaceCompositionRange(this.session, start, length, "");
    }
    this.literal(start, length, replacement);
  }

  backspace() {
    const active = this.session.active;
    const goal = [...active.visible].slice(0, -1).join('');
    let raw = active.raw;
    while (raw && this.session.kana(raw) !== goal) raw = raw.slice(0, -1);
    active.raw = raw || goal;
    this.session.replace(goal);
  }

  literal(start, length, replacement, shortcuts = true) {
    // Finish without rewriting the selection immediately before a native edit.
    this.session.finish(!this.session.atCaret());
    const punctuation = { '.': '。', ',': '、', '?': '？', '!': '！', '/': '・' };
    this.field.setRangeText(shortcuts ? (punctuation[replacement] ?? replacement) : replacement, start, start + length);
  }

  receive(reading, result) {
    if (!this.session.active || this.session.reading() !== reading) return this.snapshot();
    this.candidates = result.candidates ?? [];
    this.sections = this.manualSections
      ? expandSectionChoices(resolveBoundaries(this.sections, reading, this.candidates), reading, this.candidates)
      : phraseSections(reading, this.candidates);
    return this.snapshot();
  }

  focusSection(direction) {
    if (this.sections.length) this.selected = Math.max(0, Math.min(this.sections.length - 1, this.selected + direction));
    return this.snapshot();
  }

  resize(direction) {
    if (!this.sections.length) return this.snapshot();
    this.selected = Math.max(0, this.selected);
    this.manualSections = true;
    this.sections = resizedSections(this.sections, this.selected, direction, this.candidates);
    this.boundaries = this.sections.slice(1).map(part => part.start);
    return this.snapshot();
  }

  choose(index) {
    const choice = this.choices()[index];
    if (!choice || !this.session.active) return this.snapshot();
    this.session.select(this.session.active.end, this.session.active.end);
    const part = this.sections[this.selected];
    if (part) {
      const reading = this.session.reading();
      this.session.preview(reading.slice(0, part.start) + choice + reading.slice(part.start + part.reading.length));
    } else this.session.preview(choice);
    this.session.finish();
    this.resetCandidates();
    return this.snapshot();
  }

  commit() {
    this.session.finish();
    this.resetCandidates();
    return this.snapshot();
  }

  choices() {
    if (!this.session.active) return [];
    const part = this.sections[this.selected];
    const reading = part?.reading ?? this.session.reading();
    const katakana = reading.replace(/[ぁ-ゖ]/g, c => String.fromCharCode(c.charCodeAt(0) + 0x60));
    const ranked = part ? [part.text, ...part.choices] : this.candidates.map(c => c.text);
    const raw = part ? '' : this.session.active.raw;
    // Kana, katakana and the exact typed Latin spelling stay easy to reach,
    // without dropping any of the engine's ranked alternatives.
    return [...new Set([ranked[0], reading, katakana, raw, ...ranked.slice(1)].filter(Boolean))];
  }

  snapshot() {
    const active = this.session.active;
    const part = this.sections[this.selected];
    return {
      text: this.field.value,
      caret: this.field.selectionEnd,
      composition: active ? [active.start, active.end - active.start] : null,
      section: active && part ? [active.start + part.start, part.reading.length] : null,
      choices: this.choices(),
      reading: active ? this.session.reading() : '',
      boundaries: this.boundaries,
    };
  }
}

class NativeText {
  value = '';
  selectionStart = 0;
  selectionEnd = 0;
  setSelectionRange(start, end) { this.selectionStart = start; this.selectionEnd = end; }
  setRangeText(text, start, end) {
    this.value = this.value.slice(0, start) + text + this.value.slice(end);
    this.setSelectionRange(start + text.length, start + text.length);
  }
}
