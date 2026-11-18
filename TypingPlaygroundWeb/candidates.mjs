import { placeCandidates } from "./caret.mjs";

export class CandidatePicker {
  constructor(elements, choose) {
    this.elements = elements;
    this.choose = choose;
    elements.list.addEventListener("pointerdown", (event) => {
      if (event.target.closest("button")) event.preventDefault();
    });
    const reposition = () => placeCandidates(elements.input, elements.list);
    window.addEventListener("resize", reposition);
    window.addEventListener("scroll", reposition, true);
    new ResizeObserver(reposition).observe(elements.input);
    document.fonts.ready.then(reposition);
  }

  hide() {
    this.elements.list.hidden = true;
    this.elements.list.replaceChildren();
  }

  show(section) {
    const list = this.elements.list;
    list.replaceChildren(
      ...section.choices.map((text, index) => {
        const button = document.createElement("button");
        button.type = "button";
        button.lang = "ja";
        button.textContent = text;
        button.setAttribute("aria-pressed", String(index === section.selected));
        button.addEventListener("click", () => this.choose(index));
        return button;
      }),
    );
    list.hidden = false;
    list.style.height = `${Math.min(190, (section.choices.length - section.selected) * list.firstElementChild.offsetHeight + 8)}px`;
    placeCandidates(this.elements.input, list);
    // Kana sits immediately above the best suggestion, reachable with Up.
    // Start the scroller at the current choice rather than the kana row.
    list.scrollTop =
      list.children[section.selected]?.offsetTop -
      list.firstElementChild.offsetTop;
  }
}
