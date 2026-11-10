import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Loads the real widget in a real Quickshell instance so the fetch, the seen
// state and the panel can be exercised without a desktop. The bar is stubbed
// with the properties the widget reads; everything else is the shipped code.
//
// Set LOOT_DROPS_DIR to the plugin checkout. Notifications are suppressed
// through the settings so a harness run cannot fire a desktop notification,
// and the state directory is redirected so it cannot touch real user state.
ShellRoot {
  id: root

  // The paste regression, driven one case at a time. Each case points the
  // field at a stand-in producer and starts a real paste, so the real
  // Process callback decides what lands.
  readonly property var pasteCases: [
    { name: "overflow", producer: "overflow.sh" },
    { name: "timeout", producer: "timeout.sh" },
    { name: "success", producer: "ok.sh" }
  ]
  property int pasteIndex: -1
  property int pasteWait: 0
  property var pasteReport: ({})
  readonly property string producerDir:
    Quickshell.env("LOOT_DROPS_PASTE_DIR") || "/tmp"

  function beginPaste(producer) {
    var item = fieldLoader.item
    if (!item) return
    item.pasteBin = root.producerDir + "/" + producer
    // An existing value, selected. The field selects what it holds when it
    // is focused, so a paste would replace it.
    item.text = "DE"
    item.anchorPosition = 0
    item.cursorPosition = item.text.length
    item.forceActiveFocus()
    item.startPaste()
    root.pasteWait = 0
  }
  function pasteTick() {
    var item = fieldLoader.item
    if (!item) return
    if (root.pasteIndex < 0) {
      root.pasteIndex = 0
      root.beginPaste(root.pasteCases[0].producer)
      return
    }
    if (root.pasteIndex >= root.pasteCases.length) return
    root.pasteWait++
    if (item.pasting) {
      if (root.pasteWait > 150) {
        root.pasteReport[root.pasteCases[root.pasteIndex].name] = "TIMEOUT"
        root.pasteIndex++
      }
      return
    }
    root.pasteReport[root.pasteCases[root.pasteIndex].name] = item.text
    root.pasteIndex++
    if (root.pasteIndex < root.pasteCases.length) {
      root.beginPaste(root.pasteCases[root.pasteIndex].producer)
    }
  }
  Timer {
    interval: 200
    running: true
    repeat: true
    onTriggered: root.pasteTick()
  }

  FloatingWindow {
    implicitWidth: 560
    implicitHeight: 720
    color: Color.background
    visible: true

    QtObject {
      id: stubBar
      property string fontFamily: Style.font.family
      property color foreground: Color.bar.text
      property color barForeground: Color.bar.text
      property color background: Color.bar.background
      property color urgent: Color.bar.active
      property bool vertical: false
      property int barSize: Style.bar.sizeHorizontal
      property string position: "top"
      property var activePopout: null

      function requestPopout(owner) {
        if (activePopout && activePopout !== owner) activePopout.close()
        activePopout = owner
      }
      function releasePopout(owner) {
        if (activePopout === owner) activePopout = null
      }
      function showTooltip(item, text) {}
      function hideTooltip(item) {}
      function registerClickTarget(item) {}
      function unregisterClickTarget(item) {}
      function moduleWidgets(name) { return [] }
      function switchPanelFrom(panel, direction) { return false }
    }

    Rectangle {
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: Style.bar.sizeHorizontal
      color: Color.bar.background

      Loader {
        id: widgetLoader
        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        // A file:// URL, like the shell's own entryPointUrl, so the widget's
        // sibling components resolve through its directory import.
        source: "file://" + (Quickshell.env("LOOT_DROPS_DIR") || ".") + "/BarWidget.qml"
        onLoaded: {
          item.bar = stubBar
          item.moduleName = "salmun-nister.loot-drops"
          item.settings = {
            refreshMinutes: 90,
            steamEnabled: true,
            epicEnabled: true,
            gogEnabled: true,
            amazonEnabled: true,
            steamNotify: false,
            epicNotify: false,
            gogNotify: false,
            amazonNotify: false,
            country: "US"
          }
        }
      }
    }

    // The paste regression. The real EntryField is driven through the real
    // Process callback, with a stand-in producer in place of wl-paste so an
    // overflow and a timeout can be produced on demand. A transfer that did
    // not finish normally must leave the field and its selection alone: the
    // helper exits 1 with no output on an overflow, and forwards whatever
    // the producer managed to send before exiting with its status on a
    // timeout.
    Loader {
      id: fieldLoader
      anchors.fill: parent
      visible: false
      source: "file://" + (Quickshell.env("LOOT_DROPS_DIR") || ".") + "/EntryField.qml"
      onLoaded: {
        item.python = "/usr/bin/python3"
        item.cappedRun = (Quickshell.env("LOOT_DROPS_DIR") || ".") + "/lib/capped-run"
        item.maximumLength = 8
      }
    }

    // Report the resulting state so the harness run can be checked from
    // outside the window rather than by eye.
    Timer {
      interval: 12000
      running: true
      repeat: false
      onTriggered: {
        var widget = widgetLoader.item
        if (!widget) {
          console.warn("HARNESS: widget did not load")
          Qt.quit()
          return
        }
        // The panel's row model is asserted, not just the buckets. A panel that
        // binds `model:` to a property that does not exist renders nothing while
        // the buckets stay perfectly correct, so checking buckets alone let an
        // entirely invisible panel pass. This is what catches that class.
        var rows = widget.visibleGames || []
        var headers = []
        for (var i = 0; i < rows.length; i++) {
          if (rows[i].kind === "header") headers.push(rows[i].store)
        }
        // The panel only gives a store a section when it is watched and has
        // something to show, so the harness has to compare against what each
        // watched store actually returned rather than expecting all four.
        var state = widget.buckets || {}
        var on = widget.storesOn || {}
        var storeStatus = {}
        for (var s in on) {
          var b = state[s] || {}
          storeStatus[s] = {
            on: on[s] === true,
            games: (widget.visibleGamesFor ? widget.visibleGamesFor(s).length : 0),
            error: !!b.error
          }
        }
        console.log("HARNESS rows " + JSON.stringify({
          rowCount: rows.length,
          headers: headers,
          headersExpected: (function () {
            var out = []
            for (var key in storeStatus) {
              if (storeStatus[key].on
                  && (storeStatus[key].games > 0 || storeStatus[key].error))
                out.push(key)
            }
            return out
          })(),
          storeStatus: storeStatus,
          settingsRows: (widget.settingsRows ? widget.settingsRows().length : -1),
          gameRows: rows.length - headers.length,
          renderedRows: widget.renderedRows,
          laidOut: widget.rowsLaidOut(),
          metrics: widget.listMetrics(),
          panelOpened: widget.opened,
          probe: widget.rowProbe,
          column: widget.columnProbe,
          paste: root.pasteReport
        }))
        console.log("HARNESS state " + JSON.stringify({
          buckets: widget.buckets,
          seen: widget.seenState,
          hasGames: widget.hasGames,
          freshness: widget.freshness
        }))
        Qt.quit()
      }
    }
  }
}
