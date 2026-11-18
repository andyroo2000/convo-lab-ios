export function insertText(field, text) {
  const start = field.selectionStart;
  field.setRangeText(text, start, field.selectionEnd, "end");
  field.dispatchEvent(new Event("input", { bubbles: true }));
}

export function grow(field) {
  field.style.height = "auto";
  field.style.height = `${field.scrollHeight}px`;
}

export function attachNotebook(field, onStatus) {
  const key = "convolab:typing-playground:v1";
  try {
    field.value = localStorage.getItem(key) ?? "";
  } catch {
    onStatus("Browser storage is unavailable. Copy your text before closing.");
  }
  field.setSelectionRange(field.value.length, field.value.length);
  field.addEventListener("input", () => {
    grow(field);
    try {
      localStorage.setItem(key, field.value);
    } catch {
      onStatus("Could not save locally. Copy your text before closing.");
    }
  });
  new ResizeObserver(() => {
    if (field.clientWidth !== field.lastWidth) {
      field.lastWidth = field.clientWidth;
      grow(field);
    }
  }).observe(field);
  grow(field);
}

// Keep unfinished writing from the former phrase box recoverable without
// silently adding it to the notebook during a layout upgrade.
export function restoreLegacyPhrase(button, restore) {
  const key = "convolab:typing-playground:phrase:v1";
  try {
    const text = localStorage.getItem(key);
    if (!text) return;
    button.hidden = false;
    button.addEventListener("click", () => {
      restore(text);
      localStorage.removeItem(key);
      button.hidden = true;
    });
  } catch {
    // The original stored value is retained if storage is unavailable.
  }
}
