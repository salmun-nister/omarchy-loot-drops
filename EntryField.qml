import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "EntryEdit.js" as Edit

// A single-line field drawn from key events instead of a Qt text input.
//
// Qt's editable text inputs ask the clipboard for its contents whenever
// another application changes it, focused or not, with no size limit and no
// deadline; an application that owns the clipboard can stall the shared shell
// that way. This field never does. It keeps the text, caret and selection
// itself and draws them with plain Text items. The clipboard is read only when
// the user pastes with Ctrl+V or Shift+Insert, out of process through
// lib/capped-run under a total deadline, and the whole read is refused rather
// than truncated if it exceeds the byte cap. Copying writes the clipboard and
// never reads it.
//
// Single-line by design: the Settings page has two short values, so there is no
// wrapping, no line breaks and no word-wise motion. Tab, Shift+Tab and Escape
// finish editing so the panel can take the keyboard back.
Item {
  id: root

  property string text: ""
  property string placeholderText: ""
  property int maximumLength: 16
  // Optional function(text) -> bool. An edit that fails it is ignored.
  property var acceptInput: null
  // Optional function(text) -> text, applied to typed text and to pasted
  // text before it is inserted. It normalises what arrives rather than
  // rejecting it, so a paste of " us " becomes "US" instead of being thrown
  // away because it was not exactly two letters.
  property var sanitize: null
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.body
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.inputPaddingY

  // Absolute paths, passed by the caller so a symlinked plugin directory
  // resolves the helpers the same way the store fetches do.
  property string python: "/usr/bin/python3"
  property string cappedRun: ""
  property string timeoutBin: "/usr/bin/timeout"
  property string pasteBin: "/usr/bin/wl-paste"

  property int cursorPosition: 0
  property int anchorPosition: 0
  readonly property int selectionStart: Math.min(anchorPosition, cursorPosition)
  readonly property int selectionEnd: Math.max(anchorPosition, cursorPosition)
  readonly property string selectedText: text.slice(selectionStart, selectionEnd)
  readonly property bool hot: mouse.containsMouse
  readonly property var borderSpec:
    Border.controlSpec(activeFocus ? "focus" : (hot ? "hover-cursor" : "normal"),
                       foreground, accent)
  readonly property real caretWidth: Math.max(1, Style.spaceReal(1))
  readonly property real caretX: metrics.advanceWidth(text.slice(0, cursorPosition))
  // The fields are short by design; a long paste still keeps the caret in view.
  readonly property real scrollX: Math.max(0, caretX + caretWidth - inner.width)
  property bool pasting: false

  property bool _applying: false
  // Set when the user asked to leave the field, so the deferred focus check
  // does not report the same end of edit a second time.
  property bool _explicitFinish: false

  signal accepted()
  // The edit ended. "explicit" is true when the user asked for it (Enter,
  // Tab, Shift+Tab or Escape) and false when the focus simply went
  // somewhere else, including another window taking the keyboard.
  signal editingFinished(bool explicit)

  activeFocusOnTab: true
  implicitWidth: Style.space(60)
  implicitHeight: Math.max(Style.spacing.controlHeight,
    metrics.height + 2 * verticalPadding
      + Border.top(borderSpec) + Border.bottom(borderSpec))

  function measure(value) {
    return metrics.advanceWidth(value)
  }
  function current() {
    return {text: text, cursor: cursorPosition, anchor: anchorPosition}
  }
  function apply(next) {
    _applying = true
    text = next.text
    cursorPosition = next.cursor
    anchorPosition = next.anchor
    _applying = false
  }
  // A user edit: checked against the optional filter, then applied.
  function edit(next) {
    if (next.text === text) { apply(next); return true }
    if (acceptInput && !acceptInput(next.text)) return false
    apply(next)
    return true
  }
  // What the caller wants the field to hold, once the text is cleaned of
  // control characters and run through the optional normaliser.
  function sanitized(value) {
    var text = Edit.clean(value)
    return sanitize ? String(sanitize(text)) : text
  }
  function pasteText(value) {
    edit(Edit.insert(current(), sanitized(value), maximumLength))
  }
  function startPaste() {
    if (pasting || cappedRun === "") return
    pasting = true
    paste.running = true
    pasteDeadline.restart()
  }
  // The clipboard is only ever written here. Copy never reads it.
  function copy(cut) {
    if (selectedText === "") return true
    Quickshell.clipboardText = selectedText
    if (cut) edit(Edit.backspace(current()))
    return true
  }
  function positionAt(x) {
    var target = x - inner.x
    var best = 0, distance = Infinity
    for (var pos = 0; pos <= text.length; pos = Edit.next(text, pos)) {
      var d = Math.abs(measure(text.slice(0, pos)) - target)
      if (d < distance) { distance = d; best = pos }
      if (pos === text.length) break
    }
    return best
  }

  // Typed text from a key event, or "" for anything that is not plain input
  // (a shortcut, a control character, or an input-method composition). The
  // normaliser runs here too, so a character the field does not accept is
  // dropped where it arrives instead of at commit time.
  function typed(event) {
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return ""
    var value = String(event.text || "")
    if (Edit.clean(value) !== value) return ""
    return sanitize ? String(sanitize(value)) : value
  }

  function handle(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var s = current()
    switch (event.key) {
    case Qt.Key_V: if (!ctrl) break; startPaste(); return true
    case Qt.Key_Insert: if (!shift) break; startPaste(); return true
    case Qt.Key_A: if (!ctrl) break; apply(Edit.selectAll(s)); return true
    case Qt.Key_U: if (!ctrl) break; edit(Edit.clear()); return true
    case Qt.Key_C: if (!ctrl) break; return copy(false)
    case Qt.Key_X: if (!ctrl) break; return copy(true)
    case Qt.Key_Backspace: edit(Edit.backspace(s)); return true
    case Qt.Key_Delete: edit(Edit.forwardDelete(s)); return true
    case Qt.Key_Left: apply(Edit.left(s, shift)); return true
    case Qt.Key_Right: apply(Edit.right(s, shift)); return true
    case Qt.Key_Home: apply(Edit.moveTo(s, 0, shift)); return true
    case Qt.Key_End: apply(Edit.moveTo(s, text.length, shift)); return true
    case Qt.Key_Return:
    case Qt.Key_Enter:
      accepted()
      finish(true)
      return true
    case Qt.Key_Escape:
    case Qt.Key_Tab:
    case Qt.Key_Backtab:
      finish(true)
      return true
    }
    var value = typed(event)
    if (value === "") return false
    edit(Edit.insert(s, value, maximumLength))
    return true
  }

  onTextChanged: if (!_applying) {
    cursorPosition = text.length
    anchorPosition = cursorPosition
  }

  // The user asked to stop editing: the panel takes the keyboard back.
  function finish(explicit) {
    if (explicit) _explicitFinish = true
    editingFinished(explicit)
  }

  onActiveFocusChanged: {
    if (activeFocus) {
      // Selecting the value means typing replaces it, which is what a short
      // code or a number needs: "90" becomes "45" without a manual select.
      _explicitFinish = false
      apply(Edit.selectAll(current()))
      return
    }
    // The focus went elsewhere, or the window lost the keyboard: the
    // clipboard picker takes it, then closes and pastes with Shift+Insert.
    // Neither is the user leaving the field, so the focus item stays here
    // and that paste still lands in this field.
    Qt.callLater(function() {
      if (root.activeFocus || root._explicitFinish) return
      root.editingFinished(false)
    })
  }

  Keys.onPressed: function(event) {
    if (handle(event)) {
      event.accepted = true
      blink.on = true
      blink.restart()
    }
  }

  FontMetrics {
    id: metrics
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
  }

  BorderSurface {
    anchors.fill: parent
    color: Style.controlFill(root.activeFocus, root.hot, root.foreground, root.accent)
    borderSpec: root.borderSpec
    radius: Style.cornerRadius
  }

  Item {
    id: inner
    x: root.horizontalPadding + Border.left(root.borderSpec)
    y: root.verticalPadding + Border.top(root.borderSpec)
    width: Math.max(0, root.width - x - root.horizontalPadding
      - Border.right(root.borderSpec))
    height: Math.max(0, root.height - y - root.verticalPadding
      - Border.bottom(root.borderSpec))
    clip: true

    Rectangle {
      visible: root.activeFocus && root.selectionEnd > root.selectionStart
      x: root.measure(root.text.slice(0, root.selectionStart)) - root.scrollX
      y: (parent.height - height) / 2
      width: root.measure(root.text.slice(root.selectionStart, root.selectionEnd))
      height: metrics.height
      color: Style.selectionFillFor(root.foreground, root.accent)
    }
    Text {
      visible: root.text === ""
      width: parent.width
      height: parent.height
      verticalAlignment: Text.AlignVCenter
      textFormat: Text.PlainText
      elide: Text.ElideRight
      text: root.placeholderText
      color: Qt.darker(root.foreground, 1.6)
      font: metrics.font
    }
    Text {
      x: -root.scrollX
      width: Math.max(parent.width, root.measure(root.text))
      height: parent.height
      verticalAlignment: Text.AlignVCenter
      textFormat: Text.PlainText
      text: root.text
      color: root.foreground
      font: metrics.font
    }
    Rectangle {
      visible: root.activeFocus && blink.on
      x: root.caretX - root.scrollX
      y: (parent.height - height) / 2
      width: root.caretWidth
      height: Math.min(parent.height, metrics.font.pixelSize * 1.25)
      color: root.foreground
    }
  }

  Timer {
    id: blink
    property bool on: true
    interval: 530
    repeat: true
    running: root.activeFocus
    onRunningChanged: on = true
    onTriggered: on = !on
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.IBeamCursor
    onPressed: function(event) {
      // The first click focuses the field, and focusing selects the value;
      // a second click puts the caret where it was pressed.
      var hadFocus = root.activeFocus
      root.forceActiveFocus()
      if (hadFocus) {
        root.apply(Edit.moveTo(root.current(), root.positionAt(event.x), false))
      }
      blink.on = true
      blink.restart()
    }
  }

  // The only clipboard read: an explicit paste, out of process, under a total
  // deadline and a byte cap. The command carries no user data.
  Process {
    id: paste
    command: [
      root.python, root.cappedRun, String(Edit.PASTE_LIMIT),
      root.timeoutBin, "-k", "1", "2",
      root.pasteBin, "--no-newline", "--type", "text"
    ]
    stdout: StdioCollector { id: pasteOutput }
    onExited: function(exitCode, exitStatus) {
      pasteDeadline.stop()
      // Only a read that finished normally may change the field. An
      // overflow or a timeout must leave the value and the selection
      // alone, so the failed transfer's output is discarded rather than
      // inserted over what the user had.
      var value = Edit.pasteOutcome(exitCode, pasteOutput.text)
      if (value !== null && root.activeFocus) root.pasteText(value)
      root.pasting = false
    }
  }
  Timer {
    id: pasteDeadline
    interval: 4000
    onTriggered: {
      paste.running = false
      root.pasting = false
    }
  }
}
