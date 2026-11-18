// All ranked alternatives come from complete-phrase candidates. No section is
// sent to the engine in isolation. Kana/katakana are explicit spelling options.
function candidateSections(candidate, reading, key = "sections") {
  const sections = candidate[key] ?? [];
  if (sections.map((part) => part.reading).join("") !== reading) return [];
  if (sections.map((part) => part.text).join("") !== candidate.text) return [];
  return sections;
}

// A dictionary token can straddle a clause boundary (で食べ / でたべ).
// Split only at literal kana edges, never guess a kanji's internal reading.
function matchingEdge(text, reading, fromEnd = false) {
  let count = 0;
  const limit = Math.min(text.length, reading.length);
  while (count < limit) {
    const index = fromEnd ? -count - 1 : count;
    if (text.at(index) !== reading.at(index)) break;
    count += 1;
  }
  return count;
}

function sliceUnit(part, from, to) {
  const normalize = (text) =>
    text.replace(/[ァ-ヶ]/g, (c) =>
      String.fromCharCode(c.charCodeAt(0) - 0x60),
    );
  const text = normalize(part.text);
  const bounds = new Map([
    [0, 0],
    [part.reading.length, part.text.length],
  ]);
  const prefix = matchingEdge(text, part.reading);
  const suffix = matchingEdge(text, part.reading, true);
  for (let i = 1; i <= prefix; i += 1) bounds.set(i, i);
  for (let i = 1; i <= suffix; i += 1)
    bounds.set(part.reading.length - i, part.text.length - i);
  return bounds.has(from) && bounds.has(to)
    ? part.text.slice(bounds.get(from), bounds.get(to))
    : null;
}

function alignedText(parts, start, end) {
  let offset = 0;
  let text = "";
  for (const part of parts) {
    const next = offset + part.reading.length;
    if (offset < end && next > start) {
      const slice = sliceUnit(
        part,
        Math.max(0, start - offset),
        Math.min(part.reading.length, end - offset),
      );
      if (slice === null) return null;
      text += slice;
    }
    offset = next;
  }
  return offset >= end && text ? text : null;
}

export function spellings(reading, top, alternatives) {
  const katakana = reading.replace(/[ぁ-ゖ]/g, (char) =>
    String.fromCharCode(char.charCodeAt(0) + 0x60),
  );
  return [
    ...new Set([reading, top, ...alternatives, katakana].filter(Boolean)),
  ];
}

export function alignedAlternatives(candidates, reading, start, end) {
  return candidates.map(
    (candidate) =>
      alignedText(candidateSections(candidate, reading, "units"), start, end) ??
      alignedText(candidateSections(candidate, reading), start, end),
  );
}

// Enrich existing boundaries and preserve both selected spelling and menu order.
export function expandSectionChoices(sections, reading, candidates) {
  return sections.map((section) => {
    const alternatives = alignedAlternatives(
      candidates,
      reading,
      section.start,
      section.start + section.reading.length,
    );
    const choices = [
      ...new Set([...section.choices, ...alternatives].filter(Boolean)),
    ];
    return { ...section, choices, selected: choices.indexOf(section.text) };
  });
}

export function phraseSections(reading, candidates) {
  if (!candidates.length) return [];
  const all = candidates.map((candidate) =>
    candidateSections(candidate, reading),
  );
  const primary = all[0].length
    ? all[0]
    : [{ reading, text: candidates[0].text }];
  let start = 0;
  return primary.map((part) => {
    const end = start + part.reading.length;
    const alternatives = alignedAlternatives(candidates, reading, start, end);
    const choices = spellings(part.reading, part.text, alternatives);
    const section = {
      ...part,
      start,
      choices,
      selected: choices.indexOf(part.text),
    };
    start = end;
    return section;
  });
}

// Keep explicit choices when later context changes a clause boundary. Only the
// overlapping remainder falls back to kana; unrelated clauses retain neural text.
export function preserveChoices(sections, pins) {
  let result = sections;
  for (const pin of pins) {
    const end = pin.start + pin.reading.length;
    const overlap = result.filter(
      (s) => s.start < end && s.start + s.reading.length > pin.start,
    );
    if (!overlap.length) continue;
    const first = overlap[0];
    const reading = overlap.map((s) => s.reading).join("");
    const from = pin.start - first.start;
    if (reading.slice(from, from + pin.reading.length) !== pin.reading)
      continue;
    const before = reading.slice(0, from);
    const after = reading.slice(from + pin.reading.length);
    const replacements = [
      kanaSection(before, first.start),
      pin,
      kanaSection(after, end),
    ].filter(Boolean);
    const index = result.indexOf(first);
    result = [
      ...result.slice(0, index),
      ...replacements,
      ...result.slice(index + overlap.length),
    ];
  }
  return result;
}

function kanaSection(reading, start) {
  return reading
    ? {
        reading,
        start,
        text: reading,
        choices: spellings(reading, reading, []),
        selected: 0,
      }
    : null;
}
