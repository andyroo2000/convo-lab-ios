// Preserve original romaji where the edit aligns with a complete kana token.
// Inside a combined sound (きゃ), keep the remaining visible kana literally.
function rawPrefix(session, raw, visible) {
  for (let end = raw.length; end >= 0; end--) {
    if (session.kana(raw.slice(0, end)) === visible) return raw.slice(0, end);
  }
  return visible;
}

function rawSuffix(session, raw, visible) {
  for (let start = 0; start <= raw.length; start++) {
    if (session.kana(raw.slice(start)) === visible) return raw.slice(start);
  }
  return visible;
}

export function replaceCompositionRange(session, start, length, input) {
  const active = session.active;
  const offset = start - active.start;
  const prefix = rawPrefix(session, active.raw, active.visible.slice(0, offset));
  const suffix = rawSuffix(session, active.raw, active.visible.slice(offset + length));
  active.raw = prefix + input + suffix;
  session.replace(session.kana(active.raw));
  const caret = Math.min(active.end, active.start + session.kana(prefix + input).length);
  session.select(caret, caret);
}

// UIKit's direct delete/replace APIs may skip shouldChangeTextIn. Reconcile the
// smallest changed range so a native deletion does not discard composition.
export function changedRange(before, after) {
  let start = 0;
  const commonLength = Math.min(before.length, after.length);
  while (start < commonLength && before[start] === after[start]) start++;
  let end = before.length, nextEnd = after.length;
  while (Math.min(end, nextEnd) > start && before[end - 1] === after[nextEnd - 1]) { end--; nextEnd--; }
  return { range: [start, end - start], replacement: after.slice(start, nextEnd) };
}
