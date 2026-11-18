import { toHiragana } from 'wanakana';
import { InlineEditor } from './inline-editor.mjs';
import { watchReadiness } from './readiness.mjs';
import { JournalBinding } from './journal-binding.mjs';

const input = document.getElementById('notebook');
const elements = Object.fromEntries(['status', 'metrics'].map(id => [id, document.getElementById(id)]));
Object.assign(elements, { input, list: document.getElementById('candidates') });
const editor = new InlineEditor(elements, toHiragana);
const binding = new JournalBinding(editor);
window.journal = binding;
watchReadiness(state => binding.setReady(state === 'ready'));
const composition = document.getElementById('composition');
composition.addEventListener('pointerdown', event => {
  if (event.target.closest('button')) event.preventDefault();
});
composition.addEventListener('click', event => {
  const button = event.target.closest('button');
  if (!button) return;
  if (button.dataset.key) editor.compositionKey({ key: button.dataset.key, shiftKey: button.dataset.shift === 'true' });
  const actions = {
    convert: () => editor.convert(),
    commit: () => editor.finish(),
    kana: () => editor.escape(),
    mode: () => { button.textContent = editor.toggleMode() ? 'ABC' : 'あ'; },
  };
  actions[button.dataset.action]?.();
  input.focus();
  binding.report();
});
window.addEventListener('pagehide', () => editor.finish());
