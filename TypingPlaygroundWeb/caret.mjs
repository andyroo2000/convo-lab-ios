export function placeCandidates(field, panel) {
  if (panel.hidden) return;
  const mirror = document.createElement("div");
  const style = getComputedStyle(field);
  for (const property of [
    "font",
    "letterSpacing",
    "lineHeight",
    "padding",
    "border",
    "boxSizing",
    "tabSize",
  ])
    mirror.style[property] = style[property];
  Object.assign(mirror.style, {
    position: "fixed",
    visibility: "hidden",
    left: "0",
    top: "0",
    width: `${field.getBoundingClientRect().width}px`,
    whiteSpace: "pre-wrap",
    overflowWrap: "break-word",
  });
  mirror.textContent = field.value.slice(0, field.selectionStart);
  const marker = document.createElement("span");
  marker.textContent =
    field.value.slice(field.selectionStart, field.selectionStart + 1) ||
    "\u200b";
  mirror.append(marker);
  document.body.append(mirror);
  const caret = marker.getBoundingClientRect();
  const rect = field.getBoundingClientRect();
  const x = rect.left + caret.left - field.scrollLeft;
  const y = rect.top + caret.top - field.scrollTop;
  mirror.remove();
  positionPanel(panel, { x, y, lineHeight: parseFloat(style.lineHeight) });
}

function positionPanel(panel, caret) {
  const toolbar = document.getElementById("composition").offsetHeight;
  const bottom = innerHeight - toolbar - 12;
  const above = Math.max(0, caret.y - 12);
  const below = Math.max(0, bottom - caret.y - caret.lineHeight - 4);
  const preferAbove = above >= 76 || above >= below;
  const room = preferAbove ? above : below;
  const bounds = panel.getBoundingClientRect();
  const height = Math.min(bounds.height, Math.max(40, room - 8));
  panel.style.height = `${height}px`;
  const top = preferAbove ? caret.y - height - 8 : caret.y + caret.lineHeight + 4;
  panel.style.left = `${Math.max(12, Math.min(caret.x, innerWidth - bounds.width - 12))}px`;
  panel.style.top = `${Math.max(12, Math.min(top, bottom - height))}px`;
}
