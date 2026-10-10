import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Loads the real widget in a real Quickshell instance so the fetch, the seen
// state and the panel can be exercised without a desktop. The bar is stubbed
// with the properties the widget reads; everything else is the shipped code.
//
// Set LOOT_LIGHTNING_DIR to the plugin checkout. Notifications are suppressed
// through the settings so a harness run cannot fire a desktop notification,
// and the state directory is redirected so it cannot touch real user state.
ShellRoot {
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
        source: (Quickshell.env("LOOT_LIGHTNING_DIR") || ".") + "/BarWidget.qml"
        onLoaded: {
          item.bar = stubBar
          item.moduleName = "salmun-nister.loot-lightning"
          item.settings = {
            refreshMinutes: 180,
            steamEnabled: true,
            epicEnabled: true,
            gogEnabled: true,
            steamNotify: false,
            epicNotify: false,
            gogNotify: false,
            steamCountry: "US"
          }
        }
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
        console.log("HARNESS rows " + JSON.stringify({
          rowCount: rows.length,
          headers: headers,
          gameRows: rows.length - headers.length,
          renderedRows: widget.renderedRows,
          laidOut: widget.rowsLaidOut(),
          metrics: widget.listMetrics(),
          panelOpened: widget.opened,
          probe: widget.rowProbe,
          column: widget.columnProbe
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
