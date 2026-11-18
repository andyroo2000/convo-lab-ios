export class NotebookHistory {
  undoStack = [];
  redoStack = [];

  constructor(field, changed) {
    this.field = field;
    this.changed = changed;
    this.current = this.snapshot();
  }

  snapshot() {
    return {
      value: this.field.value,
      start: this.field.selectionStart,
      end: this.field.selectionEnd,
    };
  }

  remember() {
    if (this.current.value === this.field.value) {
      this.current = this.snapshot();
      return;
    }
    this.undoStack.push(this.current);
    if (this.undoStack.length > 100) this.undoStack.shift();
    this.redoStack = [];
    this.current = this.snapshot();
  }

  move(redo) {
    this.remember();
    const source = redo ? this.redoStack : this.undoStack;
    const target = redo ? this.undoStack : this.redoStack;
    const next = source.pop();
    if (!next) return;
    target.push(this.snapshot());
    this.field.value = next.value;
    this.field.setSelectionRange(next.start, next.end);
    this.current = next;
    this.changed();
  }
}
