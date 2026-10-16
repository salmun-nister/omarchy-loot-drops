import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Renders the real Loot Drops panel against a fictional fixture, so the
// ending-soon hourglass and the unseen coin can be seen without waiting for a
// real giveaway. The bar is stubbed with the properties the widget reads;
// everything else is the shipped code.
//
// demo/run puts demo/bin first on PATH, where a curl shim serves the fixture,
// so only Epic is enabled: a live fetch would otherwise land beside it.
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
        // Resolved against this file, so the demo works wherever the checkout is.
        source: Qt.resolvedUrl("../BarWidget.qml")
        onLoaded: {
          item.bar = stubBar
          item.moduleName = "salmun-nister.loot-drops"
          item.settings = {
            refreshMinutes: 90,
            steamEnabled: false,
            epicEnabled: true,
            gogEnabled: false,
            steamNotify: false,
            epicNotify: false,
            gogNotify: false,
            steamCountry: "US"
          }
        }
      }
    }

    // Opened once the first fetch has had time to land, so the panel comes up
    // populated rather than briefly empty.
    Timer {
      interval: 1500
      running: true
      repeat: false
      onTriggered: if (widgetLoader.item) widgetLoader.item.open()
    }
  }
}
