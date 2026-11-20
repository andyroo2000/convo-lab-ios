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
  model.external('前');
  model.field.setSelectionRange(1, 1);
  type(model, 'ame');
  suggestions(model, ['雨']);
  const state = model.moveSelection([0, 0]);
  assert.equal(state.text, '前あめ');
  assert.equal(state.composition, null);
  assert.deepEqual(state.choices, []);
  assert.equal(model.choose(0).text, '前あめ');
  assert.equal(type(model, 'kono').text, 'この前あめ');
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

for (const [key, suffix] of [['.', '。'], [',', '、'], ['?', '？'], ['!', '！'], ['/', '・'], ['1', '1']]) {
  test(`typing ${key} preserves the complete conversion phrase`, () => {
    const model = new JournalNativeSession(toHiragana);
    type(model, 'ame');
    const state = type(model, key);
    assert.equal(state.text, `あめ${suffix}`);
    assert.deepEqual(state.composition, [0, 3]);
    suggestions(model, [`雨${suffix}`, `飴${suffix}`]);
    assert.equal(model.choose(0).text, `雨${suffix}`);
    assert.equal(model.snapshot().composition, null);
  });
}

test('punctuation can be deleted or followed by more kana without losing conversion', () => {
  const model = new JournalNativeSession(toHiragana);
  type(model, 'hon');
  type(model, '.');
  assert.equal(model.snapshot().reading, 'ほん。');
  type(model, '', [2, 1]);
  assert.equal(model.snapshot().reading, 'ほん');
  type(model, 'wo');
  assert.equal(model.snapshot().text, 'ほんを');
  assert.notEqual(model.snapshot().composition, null);
});

test('cursor edits inside a phrase preserve the full reading and surrounding document', () => {
  const model = new JournalNativeSession(toHiragana);
  model.external('前後');
  model.field.setSelectionRange(1, 1);
  type(model, 'kyouhaiitenki');
  model.moveSelection([8, 0]);
  const state = model.edit({ text: model.snapshot().text, range: [7, 1], replacement: '', selection: [8, 0] });
  assert.equal(state.text, '前きょうはいいんき後');
  assert.equal(state.reading, 'きょうはいいんき');
  assert.notEqual(state.composition, null);
  type(model, 'te');
  assert.equal(model.snapshot().text, '前きょうはいいてんき後');
  assert.equal(model.snapshot().reading, 'きょうはいいてんき');
});


test('native deletion reconciles inside composition and allows continued typing', () => {
  const model = new JournalNativeSession(toHiragana);
  type(model, 'kyouhaiitenki');
  let state = model.reconcile('きょうはいいてき', [7, 0]);
  assert.equal(state.reading, 'きょうはいいてき');
  assert.notEqual(state.composition, null);
  state = type(model, "nn");
  assert.equal(state.reading, 'きょうはいいてんき');
  assert.notEqual(state.composition, null);
});


test('confirming a section keeps the suffix editable and sends full context', () => {
  const model = new JournalNativeSession(toHiragana);
  type(model, 'kyouhaiitenki');
  model.receive('きょうはいいてんき', { candidates: [{text:'今日はいい天気',sections:[{reading:'きょうは',text:'今日は'},{reading:'いいてんき',text:'いい天気'}]}] });
  model.focusSection(1);
  let state = model.choose(0);
  assert.equal(state.text, '今日はいいてんき');
  assert.deepEqual(state.composition, [3, 5]);
  assert.equal(state.reading, 'きょうはいいてんき');
  model.receive(state.reading, { candidates: [{text:'今日はいい天気',sections:[{reading:'きょうは',text:'今日は'},{reading:'いいてんき',text:'いい天気'}]}] });
  state = model.choose(0);
  assert.equal(state.text, '今日はいい天気');
  assert.equal(state.composition, null);
});

test('Space browses candidates and Enter confirms only the highlighted choice', () => {
  const model = new JournalNativeSession(toHiragana);
  type(model, 'ame'); suggestions(model, ['雨','飴']);
  let state = type(model, ' ');
  assert.equal(state.text, 'あめ');
  assert.equal(state.highlighted, 0);
  assert.notEqual(state.composition, null);
  state = type(model, '\n');
  assert.equal(state.text, '雨');
  assert.equal(state.composition, null);
});


test('section commit retains all aligned alternatives and clearing the suffix drops old context', () => {
  const model = new JournalNativeSession(toHiragana);
  type(model, 'kyouhaame');
  const candidates = Array.from({ length: 160 }, (_, i) => ({text:`今日は候補${i}`, sections:[{reading:'きょうは',text:'今日は'},{reading:'あめ',text:`候補${i}`}]}));
  model.receive('きょうはあめ', {candidates});
  model.focusSection(1); model.choose(0);
  let state = model.receive('きょうはあめ', {candidates});
  for (let i = 0; i < 160; i++) assert.ok(state.choices.includes(`候補${i}`));
  type(model, '', [3,2]);
  state = type(model, 'hon');
  assert.equal(state.reading, 'ほん');
  assert.equal(state.text, '今日はほn');
});
