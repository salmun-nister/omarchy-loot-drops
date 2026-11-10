// The clipboard boundary is a property of the QML that ships, not of one call
// site, so it is checked statically: no Qt editable text input may appear in
// runtime QML, and nothing but the paste path in EntryField.qml may touch the
// clipboard. A future field added to the Settings page has to use EntryField
// (or fail here) rather than reintroducing the native paste read.
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = fileURLToPath(new URL('../', import.meta.url));
const SKIP = new Set(['.git', '.template', 'dist', 'demo', 'tests', 'node_modules']);

function walk(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    if (SKIP.has(name)) continue;
    const full = join(dir, name);
    if (statSync(full).isDirectory()) out.push(...walk(full));
    else if (name.endsWith('.qml')) out.push(full);
  }
  return out;
}

const qml = walk(root).map(file => relative(root, file).split(sep).join('/')).sort();
const read = file => readFileSync(join(root, file), 'utf8');

test('the runtime payload is scanned, including the new field', () => {
  assert.ok(qml.includes('BarWidget.qml'), `runtime QML not found: ${qml}`);
  assert.ok(qml.includes('EntryField.qml'), `runtime QML not found: ${qml}`);
});

test('no runtime QML instantiates a Qt editable text input', () => {
  for (const file of qml) {
    const source = read(file);
    const found = source.match(/\b(TextField|TextInput|TextEdit|TextArea)\s*\{/);
    assert.equal(found, null,
      `${file} instantiates ${found && found[1]}, which reads the clipboard `
      + 'whenever another application changes it');
  }
});

test('the clipboard is read only by the bounded paste path', () => {
  for (const file of qml) {
    const source = read(file);
    if (file === 'EntryField.qml') continue;
    assert.ok(!source.includes('clipboardText'),
      `${file} touches the clipboard; only EntryField.qml may`);
    assert.ok(!source.includes('wl-paste'),
      `${file} invokes wl-paste; only EntryField.qml may`);
    assert.ok(!/\bClipboard\b/.test(source),
      `${file} references a clipboard API; only EntryField.qml may`);
  }
});

test('EntryField only writes the clipboard, and copies through the helper', () => {
  const source = read('EntryField.qml');
  const uses = source.match(/Quickshell\.clipboardText(?!\s*=)/g) || [];
  assert.deepEqual(uses, [], 'a clipboard read is not allowed outside the paste process');
  assert.match(source, /Quickshell\.clipboardText\s*=\s*selectedText/,
    'copy writes the selection and never reads');

  // One clipboard read: on paste, through lib/capped-run under timeout, with
  // the byte cap taken from EntryEdit.PASTE_LIMIT.
  assert.match(source, /root\.cappedRun/);
  assert.match(source, /root\.timeoutBin/);
  assert.match(source, /root\.pasteBin/);
  assert.match(source, /wl-paste/);
  assert.match(source, /Edit\.PASTE_LIMIT/);
  assert.ok(!/\bsh\b\s*,\s*"-c"/.test(source),
    'the paste command must not go through a shell');
});

test('the paste deadline is bounded and outlasts the read', () => {
  const source = read('EntryField.qml');
  const deadline = /id:\s*pasteDeadline[\s\S]*?interval:\s*(\d+)/.exec(source);
  assert.ok(deadline, 'no paste deadline found');
  assert.ok(Number(deadline[1]) >= 2000,
    'the watchdog must outlast the two-second read');
  assert.match(source, /timeoutBin,\s*"-k",\s*"1",\s*"2"/,
    'the clipboard read itself must have a two-second deadline');
});

test('losing the focus does not take the keyboard back from the field', () => {
  const field = read('EntryField.qml');
  const widget = read('BarWidget.qml');

  // The clipboard picker takes the keyboard, then closes and pastes with
  // Shift+Insert. If the field gave the keyboard back to the panel when
  // the window lost it, that paste went to the key catcher and landed
  // nowhere. So an implicit end of edit must not move the focus, and only
  // an explicit one (Enter, Tab, Escape) may.
  assert.match(field, /editingFinished\(false\)/,
    'losing the focus ends the edit without asking for the keyboard back');
  assert.match(field, /finish\(true\)/,
    'the explicit finishes go through the other path');
  assert.match(widget, /onEditingFinished: function\(explicit\)/);
  assert.match(widget, /if \(explicit\) root\.leaveEditor\(/,
    'the panel takes the keyboard back only when the user asked to leave');
});

test('the country field takes exactly two letters', () => {
  const widget = read('BarWidget.qml');
  const block = /id:\s*countryField[\s\S]*?\n          \}/.exec(widget);
  assert.ok(block, 'the country field was not found');
  const source = block[0];
  assert.match(source, /maximumLength:\s*2/,
    'ISO 3166-1 alpha-2 is two letters');
  assert.match(source, /sanitize:\s*function\(value\)\s*\{\s*return Model\.countryInput\(value\)\s*\}/,
    'the field normalises what is typed and pasted');
  assert.match(source, /acceptInput:\s*function\(value\)\s*\{\s*return \/\^\[A-Z\]\*\$\/\.test\(value\)\s*\}/);
});

test('a paste only lands when the read finished normally', () => {
  const source = read('EntryField.qml');
  assert.match(source, /onExited: function\(exitCode/,
    'the exit handler must see the status of the read');
  assert.match(source, /Edit\.pasteOutcome\(exitCode/,
    'the decision belongs to the helper the unit tests drive');
  assert.ok(!/if \(root\.activeFocus\) root\.pasteText\(pasteOutput\.text\)/.test(source),
    "the output of a failed read must never be inserted; an overflow exits 1 "
    + 'with no output and a timeout forwards partial output with a nonzero '
    + 'status');
});
