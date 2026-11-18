import test from 'node:test';
import assert from 'node:assert/strict';
import { toHiragana } from 'wanakana';
import { JournalNativeSession } from './journal-native-session.mjs';

function type(model, replacement, range) {
  const { text, caret } = model.snapshot();
  return model.edit({ text, range: range ?? [caret, 0], replacement, selection: [caret, 0] });
}
function suggestions(model, texts) {
  return model.receive(model.snapshot().reading, { candidates: texts.map(text => ({ text })) });
}

test('incremental kana stays unchanged by full candidate results until a tap', () => {
  const model = new JournalNativeSession(toHiragana);
  for (const char of 'kyouhatanoshikatta') type(model, char);
  const before = model.snapshot();
  assert.equal(before.text, 'きょうはたのしかった');
  const alternatives = ['今日は楽しかった', ...Array.from({ length: 100 }, (_, i) => `候補${i}`)];
  const state = suggestions(model, alternatives);
  assert.equal(state.text, before.text);
  assert.equal(state.caret, before.caret);
  for (const choice of alternatives) assert.ok(state.choices.includes(choice));
  assert.ok(state.choices.includes('kyouhatanoshikatta'));
  assert.ok(state.choices.includes('キョウハタノシカッタ'));
  assert.equal(model.choose(0).text, '今日は楽しかった');
  assert.equal(model.snapshot().composition, null);
});

test('typed Latin is available for explicit commit', () => {
  const model = new JournalNativeSession(toHiragana);
  type(model, 'OpenAI');
  const index = model.snapshot().choices.indexOf('OpenAI');
  assert.ok(index >= 0);
  assert.equal(model.choose(index).text, 'OpenAI');
});

test('backspace handles composition and committed text', () => {
  const model = new JournalNativeSession(toHiragana);
  type(model, 'ohayou');
  type(model, '', [3, 1]);
  assert.equal(model.snapshot().text, 'おはよ');
  type(model, 'u');
  model.commit();
  assert.equal(type(model, '', [3, 1]).text, 'おはよ');
  assert.equal(type(model, 'u').text, 'おはよう');
});

test('punctuation shortcut and selected replacement preserve surrounding text', () => {
  const model = new JournalNativeSession(toHiragana);
  model.external('前🙂後');
  const state = model.edit({ text: '前🙂後', range: [1, 2], replacement: 'ame', selection: [1, 2] });
  assert.equal(state.text, '前あめ後');
  model.commit();
  assert.equal(type(model, '/').text, '前あめ・後');
});

test('stale suggestions are ignored after a new reading or document', () => {
  const model = new JournalNativeSession(toHiragana);
  type(model, 'ame');
  type(model, 'ga');
  assert.equal(model.receive('あめ', { candidates: [{ text: '雨' }] }).choices.includes('雨'), false);
  model.external('別の日');
  assert.deepEqual(model.receive('あめが', { candidates: [{ text: '雨が' }] }).choices, []);
});

test('boundary adjustments keep whole-phrase reading for neural requests', () => {
  const model = new JournalNativeSession(toHiragana);
  type(model, 'hashidetabemashita');
  model.receive('はしでたべました', { candidates: [{ text: '箸で食べました', sections: [
    { reading: 'はしで', text: '箸で' }, { reading: 'たべました', text: '食べました' },
  ] }] });
  model.focusSection(1);
  const adjusted = model.resize(-1);
  assert.equal(adjusted.reading, 'はしでたべました');
  assert.deepEqual(adjusted.boundaries, [2]);
  assert.equal(adjusted.text, 'はしでたべました');
});

test('moving the caret outside composition clears stale suggestions without moving text', () => {
  const model = new JournalNativeSession(toHiragana);
  type(model, 'ame');
  suggestions(model, ['雨']);
  const state = model.moveSelection([0, 0]);
  assert.equal(state.text, 'あめ');
  assert.equal(state.composition, null);
  assert.deepEqual(state.choices, []);
  assert.equal(model.choose(0).text, 'あめ');
  assert.equal(type(model, 'kono').text, 'このあめ');
});

test('Latin option survives editing kana and pending n resolves before punctuation', () => {
  const model = new JournalNativeSession(toHiragana);
  type(model, 'ohayou');
  type(model, '', [3, 1]);
  assert.ok(model.snapshot().choices.includes('ohayo'));
  type(model, 'u');
  assert.ok(model.snapshot().choices.includes('ohayou'));
  model.external('');
  type(model, 'hon');
  assert.equal(type(model, '.').text, 'ほん。');
});

test('literal paste preserves single Latin characters, punctuation and URLs while composing', () => {
  const model = new JournalNativeSession(toHiragana);
  type(model, 'hon');
  for (const replacement of ['a', '/', 'https://example.com\n']) {
    const { text, caret } = model.snapshot();
    model.edit({ text, range: [caret, 0], replacement, selection: [caret, 0], literal: true });
  }
  assert.equal(model.snapshot().text, 'ほんa/https://example.com\n');
  assert.equal(model.snapshot().composition, null);
});
