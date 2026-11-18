export class CompositionView {
  constructor(field) {
    this.field = field;
    this.layer = document.createElement("div");
    this.layer.className = "composition-layer";
    this.layer.setAttribute("aria-hidden", "true");
    field.parentNode.append(this.layer);
  }

  render(active, sections = [], selected = -1) {
    const field = this.field;
    this.layer.hidden = !active;
    field.classList.toggle("composing", Boolean(active));
    if (!active) return;
    const prefix = document.createTextNode(field.value.slice(0, active.start));
    const suffix = document.createTextNode(
      field.value.slice(active.end) + "\u200b",
    );
    const parts = sections.length ? sections : [{ text: active.visible }];
    const spans = parts.map((part, index) => {
      const span = document.createElement("span");
      span.textContent = part.text;
      span.className =
        index === selected
          ? "composition-section current"
          : "composition-section";
      return span;
    });
    this.layer.replaceChildren(prefix, ...spans, suffix);
  }
}
