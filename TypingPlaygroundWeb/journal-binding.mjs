export class JournalBinding {
  revision = 0;
  enabled = false;
  ready = false;
  scheduled = false;

  constructor(editor) {
    this.editor = editor;
    this.input = editor.field;
    this.input.addEventListener('input', () => this.changed());
    this.input.addEventListener('focus', () => this.report());
    this.input.addEventListener('blur', () => this.report());
    this.input.addEventListener('keyup', () => this.report());
    this.input.addEventListener('click', () => this.report());
    new ResizeObserver(() => this.report()).observe(document.body);
    new MutationObserver(() => this.report()).observe(document.getElementById('input-tools'), { subtree: true, childList: true, attributes: true, attributeFilter: ['hidden', 'data-state', 'disabled'], characterData: true });
    document.fonts.ready.then(() => this.report());
  }

  configure(text, settings, revision) {
    if (revision !== this.revision) {
      this.editor.finish();
      this.revision = revision;
      if (this.input.value !== text) {
        this.input.value = text;
        this.editor.history.undoStack = [];
        this.editor.history.redoStack = [];
        this.editor.history.current = this.editor.history.snapshot();
      }
    }
    this.enabled = settings.enabled;
    this.input.setAttribute('aria-label', settings.label);
    const style = document.body.style;
    style.setProperty('--writing-font', settings.font);
    style.setProperty('--writing-size', `${settings.size}px`);
    style.setProperty('--pitch', `${settings.size * 2.7}px`);
    style.setProperty('--lines', settings.lines);
    this.applyReadiness();
    this.report();
  }

  setReady(ready) {
    this.ready = ready;
    this.applyReadiness();
  }

  applyReadiness() {
    const ready = this.ready && this.enabled;
    if (this.editor.ready !== ready) this.editor.setReady(ready);
    document.getElementById('composition').disabled = !ready;
    this.input.readOnly = !ready;
    this.report();
  }

  changed() {
    this.post({ path: 'journal/change', text: this.input.value, revision: this.revision });
    this.report();
  }

  post(message) {
    window.webkit.messageHandlers.typingEngine.postMessage(message).catch(() => {});
  }

  report() {
    if (this.scheduled) return;
    this.scheduled = true;
    requestAnimationFrame(() => {
      this.scheduled = false;
      this.input.style.height = 'auto';
      this.input.style.height = `${this.input.scrollHeight}px`;
      this.layoutTools();
    });
  }

  layoutTools() {
    const focused = document.activeElement === this.input;
    const caret = this.caretTop();
    const tools = document.getElementById('input-tools');
    tools.hidden = !focused && this.ready;
    const pitch = parseFloat(getComputedStyle(this.input).lineHeight);
    tools.style.top = `${focused ? caret + pitch : this.input.offsetHeight}px`;
    const bottom = tools.hidden ? 0 : tools.offsetTop + tools.offsetHeight;
    document.body.style.minHeight = `${Math.max(this.input.offsetHeight, bottom)}px`;
    this.post({ path: 'journal/layout', height: Math.ceil(document.body.getBoundingClientRect().height),
      focused, caret, revealHeight: tools.hidden ? pitch : pitch + tools.offsetHeight });
  }

  caretTop() {
    const mirror = document.createElement('div');
    mirror.className = 'composition-layer';
    mirror.style.position = 'absolute';
    mirror.style.visibility = 'hidden';
    mirror.style.height = 'auto';
    mirror.textContent = this.input.value.slice(0, this.input.selectionEnd);
    const marker = document.createElement('span');
    marker.textContent = '\u200b';
    mirror.append(marker);
    this.input.parentElement.append(mirror);
    const top = marker.offsetTop;
    mirror.remove();
    return top;
  }
}
