.pragma library
// Text editing for EntryField, free of Qt so Node can test it.
//
// A state is {text, cursor, anchor}; the selection runs between anchor and
// cursor. Every function returns a new state and leaves its input alone.
//
// This is deliberately smaller than a general text editor: the Settings page
// has two short single-line values, so there is no wrapping, no line breaks and
// no word-wise motion. What remains is the property that matters for the
// clipboard boundary: text only ever enters through `insert`, which is capped
// and goes through `clean`.

// The most a paste may insert. lib/capped-run refuses a clipboard read larger
// than this, so a hostile owner cannot grow the shell's memory.
var PASTE_LIMIT = 4096

function clamp(value, low, high) {
    return Math.max(low, Math.min(high, Number(value) || 0));
}

function state(text, cursor, anchor) {
    text = String(text == null ? "" : text);
    var at = clamp(cursor === undefined ? text.length : cursor, 0, text.length);
    return {
        text: text,
        cursor: at,
        anchor: anchor === undefined ? at : clamp(anchor, 0, text.length)
    };
}

function selection(s) {
    return {
        start: Math.min(s.anchor, s.cursor),
        end: Math.max(s.anchor, s.cursor)
    };
}

function hasSelection(s) {
    return s.anchor !== s.cursor;
}

function selectedText(s) {
    var r = selection(s);
    return s.text.slice(r.start, r.end);
}

function isHigh(code) { return code >= 0xd800 && code <= 0xdbff; }
function isLow(code) { return code >= 0xdc00 && code <= 0xdfff; }

// Caret stops never split a surrogate pair.
function previous(text, pos) {
    if (pos <= 0) return 0;
    return pos >= 2 && isLow(text.charCodeAt(pos - 1)) && isHigh(text.charCodeAt(pos - 2))
        ? pos - 2 : pos - 1;
}

function next(text, pos) {
    if (pos >= text.length) return text.length;
    return pos + 2 <= text.length && isHigh(text.charCodeAt(pos)) && isLow(text.charCodeAt(pos + 1))
        ? pos + 2 : pos + 1;
}

// Text from a key event or the clipboard, without control characters. A
// single-line field turns a line break or tab into a space so words do not
// merge, and drops every other C0/C1 control character. A paste cut at the byte
// cap can end in a replacement character or half a surrogate pair, so that
// fragment is dropped rather than inserted.
function clean(value) {
    var text = String(value == null ? "" : value)
        .replace(/\r\n?/g, "\n")
        .replace(/[\n\t]/g, " ")
        .replace(/[\u0000-\u001f\u007f-\u009f]/g, "");
    text = text.replace(/\uFFFD+$/, "");
    if (text.length && isHigh(text.charCodeAt(text.length - 1))) {
        text = text.slice(0, -1);
    }
    return text;
}

// Trim a value to the room left, without leaving half a surrogate pair.
function fit(value, room) {
    if (value.length <= room) return value;
    value = value.slice(0, Math.max(0, room));
    if (value.length && isHigh(value.charCodeAt(value.length - 1))) {
        value = value.slice(0, -1);
    }
    return value;
}

// Replace the selection, or insert at the caret, within maxLength.
function insert(s, value, maxLength) {
    var r = selection(s);
    var limit = maxLength === undefined ? Infinity : maxLength;
    value = fit(String(value), limit - (s.text.length - (r.end - r.start)));
    var text = s.text.slice(0, r.start) + value + s.text.slice(r.end);
    var cursor = r.start + value.length;
    return {text: text, cursor: cursor, anchor: cursor};
}

function cut(s, start, end) {
    return {
        text: s.text.slice(0, start) + s.text.slice(end),
        cursor: start,
        anchor: start
    };
}

function backspace(s) {
    if (hasSelection(s)) {
        var r = selection(s);
        return cut(s, r.start, r.end);
    }
    return cut(s, previous(s.text, s.cursor), s.cursor);
}

function forwardDelete(s) {
    if (hasSelection(s)) {
        var r = selection(s);
        return cut(s, r.start, r.end);
    }
    return cut(s, s.cursor, next(s.text, s.cursor));
}

function clear() {
    return {text: "", cursor: 0, anchor: 0};
}

function selectAll(s) {
    return {text: s.text, cursor: s.text.length, anchor: 0};
}

// Move the caret. Without extend, a selection collapses toward the move.
function moveTo(s, pos, extend) {
    pos = clamp(pos, 0, s.text.length);
    return {text: s.text, cursor: pos, anchor: extend ? s.anchor : pos};
}

function left(s, extend) {
    if (!extend && hasSelection(s)) return moveTo(s, selection(s).start, false);
    return moveTo(s, previous(s.text, s.cursor), extend);
}

function right(s, extend) {
    if (!extend && hasSelection(s)) return moveTo(s, selection(s).end, false);
    return moveTo(s, next(s.text, s.cursor), extend);
}
