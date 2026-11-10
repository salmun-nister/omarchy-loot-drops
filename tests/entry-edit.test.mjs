// EntryEdit.js is a QML pragma library, so it is loaded here as plain
// JavaScript by stripping the directive. The tests drive the real editing
// operations the Settings fields use, including the clipboard cleanup.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import assert from 'node:assert/strict';

const here = new URL('./', import.meta.url);
const root = new URL('../', here);
const source = readFileSync(new URL('EntryEdit.js', root), 'utf8')
  .replace(/^\.pragma\s+library\s*$/m, '');
const Edit = new Function(`"use strict";\n${source}\nreturn {
  PASTE_LIMIT, state, selection, hasSelection, selectedText, insert, cut,
  backspace, forwardDelete, clear, selectAll, moveTo, left, right, clean, fit,
  previous, next, pasteOutcome,
};`)();

test('state clamps the caret to the text', () => {
  assert.deepEqual(Edit.state('abc'), { text: 'abc', cursor: 3, anchor: 3 });
  assert.equal(Edit.state('abc', 99).cursor, 3);
  assert.equal(Edit.state('abc', -4).cursor, 0);
  assert.equal(Edit.state(null).text, '');
});

test('insert replaces a selection and respects the maximum length', () => {
  const all = Edit.selectAll(Edit.state('90'));
  assert.equal(Edit.insert(all, '45', 3).text, '45');
  assert.equal(Edit.insert(Edit.state('90'), '45', 3).text, '904',
    'only the room left is filled');
  assert.equal(Edit.insert(Edit.state(''), '12345', 3).text, '123');
  assert.equal(Edit.insert(Edit.state('90'), '45').text, '9045',
    'no maximum means no truncation');
});


test('insert never leaves half a surrogate pair at the cap', () => {
  const two = Edit.insert(Edit.state(''), 'a\u{1F600}', 2);
  assert.equal(two.text, 'a', 'the emoji would be split by a 2-unit cap');
  const three = Edit.insert(Edit.state(''), 'a\u{1F600}', 3);
  assert.equal(three.text, 'a\u{1F600}');
});

test('backspace and forward delete respect a selection and surrogate pairs', () => {
  assert.equal(Edit.backspace(Edit.state('abc', 2)).text, 'ac');
  assert.equal(Edit.backspace(Edit.state('abc', 0)).text, 'abc');
  assert.equal(Edit.forwardDelete(Edit.state('abc', 1)).text, 'ac');
  assert.equal(Edit.forwardDelete(Edit.state('abc', 3)).text, 'abc');

  const emoji = Edit.state('a\u{1F600}b', 3);
  assert.equal(Edit.backspace(emoji).text, 'ab');
  assert.equal(Edit.forwardDelete(Edit.state('a\u{1F600}b', 1)).text, 'ab');
});

test('caret movement collapses a selection unless extending', () => {
  const selected = Edit.state('abcd', 1, 3);
  assert.deepEqual(Edit.selection(selected), { start: 1, end: 3 });
  assert.equal(Edit.left(selected, false).cursor, 1);
  assert.equal(Edit.right(selected, false).cursor, 3);
  assert.equal(Edit.left(selected, true).cursor, 0);
  assert.equal(Edit.left(selected, true).anchor, 3);
  assert.equal(Edit.moveTo(selected, 99, false).cursor, 4);
});

test('select all then typing replaces the whole value', () => {
  const all = Edit.selectAll(Edit.state('US'));
  const next = Edit.insert(all, 'DE', 8);
  assert.equal(next.text, 'DE');
  assert.equal(next.cursor, 2);
});

test('clean removes control characters and keeps words apart', () => {
  assert.equal(Edit.clean('US\n'), 'US ');
  assert.equal(Edit.clean('U\tS'), 'U S');
  assert.equal(Edit.clean('a\u0000b'), 'ab');
  assert.equal(Edit.clean('a\u009fb'), 'ab');
  assert.equal(Edit.clean('a\u202eb'), 'a\u202eb',
    'direction controls are left to the title scrubber, not this field');
  assert.equal(Edit.clean('90\r\n'), '90 ');
});

test('clean drops a fragment left by a capped read', () => {
  assert.equal(Edit.clean('US\uFFFD'), 'US');
  assert.equal(Edit.clean('US\uFFFD\uFFFD'), 'US');
  const half = Edit.clean('a\uD83D');
  assert.equal(half, 'a', 'a lone high surrogate is not inserted');
});

test('the paste limit matches the byte cap the helper enforces', () => {
  assert.equal(Edit.PASTE_LIMIT, 4096);
});

test('a failed paste may not change the field', () => {
  // What the field does with a finished read: the outcome decides, and a
  // failed read has no outcome to insert.
  const applyPaste = (state, exitCode, output) => {
    const value = Edit.pasteOutcome(exitCode, output);
    if (value === null) return state;
    return Edit.insert(state, value, 8);
  };

  // An overflow: lib/capped-run exits 1 and writes no stdout at all.
  const overflow = Edit.pasteOutcome(1, '');
  assert.equal(overflow, null, 'an overflow may not change the field');

  // A timeout: the helper forwards whatever the producer managed to send
  // and exits with the status of the producer, so a failed read can carry
  // a partial string. It must be discarded, not inserted.
  const timedOut = Edit.pasteOutcome(124, 'XY');
  assert.equal(timedOut, null, 'partial output from a failed read is discarded');

  // The value and the selection survive both, where a paste that finished
  // normally would have replaced the selection.
  const selected = Edit.selectAll(Edit.state('DE'));
  assert.equal(applyPaste(selected, 1, '').text, 'DE',
    'the existing value survives an overflowed paste');
  assert.equal(applyPaste(selected, 124, 'XY').text, 'DE',
    'the existing value survives a timed-out paste');
  assert.equal(applyPaste(selected, 124, 'XY').cursor, selected.cursor,
    'the caret does not move when the paste failed');
});

test('a paste that finished normally may change the field', () => {
  assert.equal(Edit.pasteOutcome(0, 'DE'), 'DE');
  assert.equal(Edit.pasteOutcome(0, ''), '', 'an empty clipboard is not a failure');

  const selected = Edit.selectAll(Edit.state('US'));
  const value = Edit.pasteOutcome(0, 'DE');
  assert.equal(Edit.insert(selected, value, 8).text, 'DE',
    'a successful paste replaces the selected value');
});

test('a normalised value replaces the selection and fits the field', () => {
  // The field normalises what arrives before inserting it. The country
  // field's normaliser is Model.countryInput (upper case, two letters);
  // this is the same shape, and the property under test is the insert.
  const normalise = value => String(value).toUpperCase()
    .replace(/[^A-Z]/g, '').slice(0, 2);

  const selected = Edit.selectAll(Edit.state('US'));
  const next = Edit.insert(selected, normalise(' de '), 2);
  assert.equal(next.text, 'DE', 'the paste replaces the value that was there');
  assert.equal(next.cursor, 2);

  assert.equal(Edit.insert(Edit.state(''), normalise('united states'), 2).text, 'UN',
    'a long paste keeps the first two letters');
  assert.equal(Edit.insert(Edit.state(''), normalise('12'), 2).text, '',
    'a value with no letters leaves the field empty');
});
