import QtQuick
import Quickshell.Io

// Runs one external command and emits `finished(exitCode, output)` only after
// both the process has exited and stdout's StdioCollector has finished
// flushing. Process.onExited and StdioCollector.onStreamFinished can arrive in
// either order, so reading output from just one risks empty or truncated data.
Item {
  id: runner
  visible: false
  width: 0
  height: 0

  property alias command: proc.command
  property alias running: proc.running

  signal finished(int exitCode, string output)

  property bool _exited: false
  property bool _streamDone: false
  property int _exitCode: -1
  property bool _active: false

  function start(cmd) {
    if (cmd !== undefined) proc.command = cmd
    _active = true
    _exited = false
    _streamDone = false
    _exitCode = -1
    proc.running = true
  }

  function stop() {
    _active = false
    _exited = false
    _streamDone = false
    proc.running = false
  }

  function _maybeFinish() {
    if (!_active || !_exited || !_streamDone) return
    _active = false
    finished(_exitCode, collector.text)
  }

  Process {
    id: proc
    onStarted: {
      runner._active = true
      runner._exited = false
      runner._streamDone = false
      runner._exitCode = -1
    }
    stdout: StdioCollector {
      id: collector
      waitForEnd: true
      onStreamFinished: {
        runner._streamDone = true
        runner._maybeFinish()
      }
    }
    onExited: function(exitCode, exitStatus) {
      runner._exitCode = exitCode
      runner._exited = true
      runner._maybeFinish()
    }
  }
}
