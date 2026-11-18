import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JournalBinding } from './journal-binding.mjs';

function fixture() {
  const messages = [];
  const composition = {};
  const input = { value: '', style: {}, addEventListener() {}, setAttribute() {} };
  const editor = {
    field: input, ready: false, pending: true,
    finish() { this.pending = false; },
    setReady(value) { this.ready = value; if (!value) this.finish(); },
    history: { undoStack: ['older document'], redoStack: ['other text'], snapshot: () => ({ value: input.value }) },
  };
  globalThis.window = { webkit: { messageHandlers: { typingEngine: { postMessage: async value => { messages.push(value); } } } } };
  globalThis.document = { body: { style: { setProperty() {} } }, getElementById: () => composition, fonts: { ready: Promise.resolve() } };
  globalThis.ResizeObserver = class { observe() {} };
  globalThis.MutationObserver = class { observe() {} };
  globalThis.requestAnimationFrame = () => {};
  const binding = new JournalBinding(editor);
  const settings = { label: 'Journal entry', font: 'KleeOne-SemiBold', size: 20, lines: 4, enabled: true };
  return { binding, input, editor, messages, settings, composition };
}

test('an external document replacement cancels pending conversion and clears undo from the prior document', () => {
  const { binding, input, editor, settings } = fixture();
  binding.configure('保存した文章', settings, 1);
  assert.equal(input.value, '保存した文章');
  assert.equal(editor.pending, false);
  assert.deepEqual(editor.history.undoStack, []);
  assert.deepEqual(editor.history.redoStack, []);
  assert.equal(editor.history.current.value, '保存した文章');
});

test('a style update does not overwrite newer local typing with an older snapshot', () => {
  const { binding, input, messages, settings } = fixture();
  binding.configure('old', settings, 1);
  input.value = 'new local typing';
  binding.changed();
  binding.configure('old', { ...settings, size: 25 }, 1);
  assert.equal(input.value, 'new local typing');
  assert.deepEqual(messages[0], { path: 'journal/change', text: 'new local typing', revision: 1 });
});

test('loading or disabled editors cannot convert; disabling cancels outstanding conversion', () => {
  const { binding, input, editor, settings, composition } = fixture();
  binding.configure('draft', settings, 1);
  assert.equal(input.readOnly, true);
  binding.setReady(true);
  assert.equal(input.readOnly, false);
  editor.pending = true;
  binding.configure('draft', { ...settings, enabled: false }, 1);
  assert.equal(input.readOnly, true);
  assert.equal(composition.disabled, true);
  assert.equal(editor.pending, false);
});
