import {
  resizedSections,
  resolveBoundaries,
  rememberBoundaries,
} from "./section-boundaries.mjs";
import { ExpandedMenu } from "./expanded-menu.mjs";
import {
  phraseSections,
  preserveChoices,
  expandSectionChoices,
} from "./sections.mjs";
import { LiveRequest } from "./live-request.mjs";
import { CandidatePicker } from "./candidates.mjs";
import { CompositionView } from "./composition-view.mjs";

export class LiveComposition {
  sections = [];
  candidates = [];
  manualBoundaries = false;
  pins = [];
  selected = -1;
  choosing = false;

  constructor(session, elements) {
    this.session = session;
    this.elements = elements;
    this.view = new CompositionView(elements.input);
    this.expansion = new ExpandedMenu(session, elements, (reading, result) =>
      this.extendChoices(reading, result),
    );
    this.picker = new CandidatePicker(elements, (index) => this.choose(index));
    this.request = new LiveRequest(
      (job, result, elapsed) => this.receive(job, result, elapsed),
      (error) => {
        elements.status.textContent = `${error.message} Your text has been kept.`;
      },
    );
  }

  reset() {
    this.request.cancel();
    this.expansion.reset();
    this.picker.hide();
    this.sections = [];
    this.pins = [];
    this.candidates = [];
    this.manualBoundaries = false;
    this.selected = -1;
    this.choosing = false;
    this.paint();
  }

  paint() {
    this.view.render(
      this.session.active,
      this.sections,
      this.choosing ? this.selected : -1,
    );
  }

  typed() {
    this.request.cancel();
    this.expansion.reset();
    this.picker.hide();
    this.sections = [];
    this.choosing = false;
    this.paint();
    const reading = this.session.kana(this.session.active.raw);
    if (!/[a-z]/i.test(reading) && reading.length >= 2)
      this.request.schedule(reading);
  }

  convert() {
    if (this.sections.length) {
      if (this.choosing) this.moveCandidate(1);
      else this.select(0);
      return;
    }
    const reading = this.session.reading();
    this.session.restore();
    this.paint();
    if (/[a-z]/i.test(reading)) {
      this.elements.status.textContent =
        "Finish the romaji sound before converting.";
      return;
    }
    this.elements.status.textContent = "Finding kanji…";
    this.request.schedule(reading, true);
  }

  receive(job, result, elapsed) {
    if (!this.session.atCaret()) return;
    this.candidates = result.candidates;
    const sections = phraseSections(job.reading, result.candidates);
    if (!sections.length) return;
    this.sections = preserveChoices(sections, this.pins);
    this.selected = 0;
    this.session.active.convertedReading = job.reading;
    this.session.active.preview = true;
    this.session.active.convertedText = this.text();
    this.session.replace(this.text());
    this.choosing = job.immediate;
    if (this.choosing) this.select(0);
    else this.paint();
    this.elements.metrics.textContent = `${result.engineMs.toFixed(1)} ms engine · ${elapsed.toFixed(0)} ms round trip`;
    this.elements.status.textContent =
      "← → sections · ↑ ↓ choices · Enter to commit · Esc for kana.";
  }

  text() {
    return this.sections.map((part) => part.text).join("");
  }

  select(index) {
    this.request.cancel();
    this.choosing = true;
    this.selected = Math.max(0, Math.min(index, this.sections.length - 1));
    const start =
      this.session.active.start +
      this.sections
        .slice(0, this.selected)
        .map((s) => s.text)
        .join("").length;
    this.session.select(
      start,
      start + this.sections[this.selected].text.length,
    );
    this.picker.show(this.sections[this.selected]);
    this.paint();
    this.expansion.load(
      this.session.reading(),
      this.manualBoundaries ? this.sections.slice(1).map((s) => s.start) : [],
    );
  }

  extendChoices(reading, result) {
    this.candidates = result.candidates;
    this.sections = resolveBoundaries(
      this.sections,
      reading,
      result.candidates,
    );
    this.sections = expandSectionChoices(
      this.sections,
      reading,
      result.candidates,
    );
    this.pins = expandSectionChoices(this.pins, reading, result.candidates);
    if (this.manualBoundaries) this.pins = rememberBoundaries(this.sections);
    this.session.active.convertedText = this.text();
    this.session.replace(this.text());
    this.select(this.selected);
  }

  resize(direction) {
    if (!this.sections.length) return false;
    if (!this.choosing) this.selected = 0;
    const resized = resizedSections(
      this.sections,
      this.selected,
      direction,
      this.candidates,
    );
    if (resized === this.sections) {
      this.select(this.selected);
      return true;
    }
    this.expansion.reset();
    this.manualBoundaries = true;
    this.sections = resized;
    this.pins = rememberBoundaries(resized);
    this.session.active.convertedText = this.text();
    this.session.replace(this.text());
    this.select(this.selected);
    return true;
  }

  choose(index) {
    const section = this.sections[this.selected];
    section.pendingBoundary = false;
    section.selected = index;
    section.text = section.choices[index];
    this.pins = this.pins.filter((pin) => pin.start !== section.start);
    this.pins.push({ ...section });
    this.session.active.convertedText = this.text();
    this.session.replace(this.text());
    this.select(this.selected);
    this.elements.input.focus();
  }

  moveCandidate(direction) {
    const part = this.sections[this.selected];
    this.choose(
      Math.max(0, Math.min(part.selected + direction, part.choices.length - 1)),
    );
  }

  arrow(key, shift = false) {
    const resizeDirection = { ArrowLeft: -1, ArrowRight: 1 }[key];
    if (shift && resizeDirection) return this.resize(resizeDirection);
    if (!this.sections.length) return false;
    if (!this.choosing) {
      this.select(key === "ArrowLeft" ? this.sections.length - 1 : 0);
      if (key === "ArrowUp") this.moveCandidate(-1);
      return true;
    }
    const horizontal = { ArrowLeft: -1, ArrowRight: 1 }[key];
    if (horizontal) this.select(this.selected + horizontal);
    else this.moveCandidate(key === "ArrowUp" ? -1 : 1);
    return true;
  }
}
