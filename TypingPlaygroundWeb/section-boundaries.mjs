import { alignedAlternatives, spellings } from "./sections.mjs";

// Reading offsets use UTF-16, as do textarea selections. Move by a complete
// grapheme so surrogate pairs and combining marks cannot be cut in half.
export function resizedSections(sections, selected, direction, candidates) {
  const part = sections[selected];
  const next = sections[selected + 1];
  const reading = sections.map((s) => s.reading).join("");
  const end = part.start + part.reading.length;
  const step = boundaryStep(part.reading, next?.reading ?? "", direction);
  if (!step) return sections;
  const boundary = end + direction * step;
  const pairEnd = next ? next.start + next.reading.length : end;
  const ranges = [
    [part.start, boundary],
    [boundary, pairEnd],
  ];
  const replacements = ranges
    .filter(([start, stop]) => start < stop)
    .map(([start, stop]) => boundarySection(reading, start, stop, candidates));
  return [
    ...sections.slice(0, selected),
    ...replacements,
    ...sections.slice(selected + (next ? 2 : 1)),
  ];
}

function boundaryStep(reading, nextReading, direction) {
  const segments = (text) => [...new Intl.Segmenter("ja").segment(text)];
  if (direction > 0) return segments(nextReading)[0]?.segment.length ?? 0;
  const characters = segments(reading);
  return characters.length > 1 ? characters.at(-1).segment.length : 0;
}

function boundarySection(reading, start, end, candidates) {
  const kana = reading.slice(start, end);
  const alternatives = alignedAlternatives(
    candidates,
    reading,
    start,
    end,
  ).filter(Boolean);
  const text = alternatives[0] ?? kana;
  const choices = spellings(kana, text, alternatives);
  return {
    start,
    reading: kana,
    text,
    choices,
    selected: choices.indexOf(text),
    pendingBoundary: true,
  };
}

export function resolveBoundaries(sections, reading, candidates) {
  return sections.map((part) => {
    if (!part.pendingBoundary) return part;
    const resolved = boundarySection(
      reading,
      part.start,
      part.start + part.reading.length,
      candidates,
    );
    return { ...resolved, pendingBoundary: false };
  });
}

export function rememberBoundaries(sections) {
  // Appending reading must not restore the engine's automatic breaks.
  return sections.map((part) => ({ ...part }));
}
