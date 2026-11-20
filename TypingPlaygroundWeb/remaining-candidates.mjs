import { alignedAlternatives } from './sections.mjs';

// Keep the complete engine response for ranking, but only insert the uncommitted
// suffix. The committed prefix remains part of every inference request.
export function remainingCandidates(candidates, reading, offset) {
  if (!offset) return candidates;
  const endings = alignedAlternatives(candidates, reading, offset, reading.length);
  return candidates.flatMap((candidate, index) => {
    const text = endings[index];
    if (!text) return [];
    const trim = (parts = []) => {
      let cursor = 0;
      return parts.filter(part => { cursor += part.reading.length; return cursor > offset; });
    };
    return [{ ...candidate, text, sections: trim(candidate.sections), units: trim(candidate.units) }];
  });
}
