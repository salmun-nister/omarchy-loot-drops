pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// In-panel Settings page: store watches, notification toggles, store-specific
// options, and general settings. Shares the main list's slot inside BarWidget.
Item {
  id: page

  required property var widget
  property real footerButtonHeight: Style.spacing.controlHeight

  readonly property real listContentHeight: settingsList.contentHeight
  readonly property real footerImplicitHeight: settingsFooter.implicitHeight

  // Settings page: every preference in one place, grouped by store.
  ListView {
    id: settingsList
    anchors.top: parent.top
    anchors.bottom: settingsFooter.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Style.spacing.sm
    anchors.rightMargin: Style.spacing.sm
    clip: true
    model: page.widget.settingsRows()
    boundsBehavior: Flickable.StopAtBounds
    spacing: Style.spacing.sm
    flickableDirection: Flickable.VerticalFlick
    interactive: contentHeight > height

    ScrollBar.vertical: ScrollBar {
      policy: ScrollBar.AsNeeded
    }

    delegate: Item {
      id: settingRow
      required property var modelData
      required property int index
      width: settingsList.width
      readonly property bool isHeading: modelData.kind === "heading"
      // Layout height per kind, so contentHeight is real before layout.
      // Every non-heading row uses the control height, giving the General
      // section the same tight rhythm as the store sections while still
      // clearing a dropdown's hover border.
      height: isHeading ? Style.font.caption + Style.space(24)
        : Style.spacing.controlHeight

      Text {
        id: settingLabel
        anchors.left: parent.left
        // Setting rows sit indented under their store heading, the same way
        // game rows sit under a store header. Headings sit clear of their mark.
        anchors.leftMargin: settingRow.isHeading
          ? Style.space(24) + page.widget.markSize + Style.space(8)
          : page.widget.storeIndent
        anchors.verticalCenter: parent.verticalCenter
        visible: settingRow.isHeading || modelData.kind === "country"
        // Heading labels size to their text so the flanking rule on the right
        // starts right after the name; the country label fills the shared
        // column so its field starts on the same x as every other control.
        width: modelData.kind === "country"
          ? page.widget.settingsLabelColumn : implicitWidth
        textFormat: Text.PlainText
        text: settingRow.isHeading
          ? (modelData.label || "").toUpperCase()
          : ((modelData.label || "") + ":")
        color: page.widget.foreground
        font.family: page.widget.fontFamily
        font.pixelSize: settingRow.isHeading ? Style.font.body : Style.font.bodySmall
        font.bold: settingRow.isHeading
        font.letterSpacing: settingRow.isHeading ? 1.0 : 0
        elide: Text.ElideRight
      }

      // The store's mark beside its Settings heading, matching the main list
      // (Epic uses its bundled logo).
      Item {
        id: settingMark
        anchors.left: parent.left
        anchors.leftMargin: Style.space(24)
        anchors.verticalCenter: parent.verticalCenter
        width: page.widget.markSize
        height: page.widget.markSize
        visible: settingRow.isHeading

        Text {
          anchors.centerIn: parent
          visible: settingRow.isHeading && !!modelData.store && modelData.store !== "epic"
          textFormat: Text.PlainText
          text: Model.STORE_GLYPHS[modelData.store] || ""
          color: page.widget.dim
          font.family: page.widget.fontFamily
          font.pixelSize: page.widget.markSize
        }

        Text {
          anchors.centerIn: parent
          visible: settingRow.isHeading && !modelData.store
          textFormat: Text.PlainText
          text: "\u{F0AD}"
          color: page.widget.dim
          font.family: page.widget.fontFamily
          font.pixelSize: page.widget.markSize
        }

        Image {
          id: settingEpicLogo
          anchors.fill: parent
          // Only the Epic heading loads the asset and allocates an offscreen
          // texture layer; non-heading Epic rows (store, platforms, toggles)
          // must not trigger it.
          source: settingRow.isHeading && modelData.store === "epic"
            ? page.widget.pluginFile("assets/epic.svg") : ""
          fillMode: Image.PreserveAspectFit
          sourceSize.width: Math.round(width * Screen.devicePixelRatio)
          sourceSize.height: Math.round(height * Screen.devicePixelRatio)
          visible: false
          layer.enabled: settingRow.isHeading && modelData.store === "epic"
        }

        MultiEffect {
          anchors.fill: settingEpicLogo
          source: settingEpicLogo
          visible: settingRow.isHeading && modelData.store === "epic"
          colorization: 1.0
          colorizationColor: page.widget.dim
        }
      }

      // Flanking rules matching the main list.
      PanelSeparator {
        visible: settingRow.isHeading
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.sm
        anchors.right: settingMark.left
        anchors.rightMargin: Style.space(8)
        foreground: page.widget.foreground
        height: Style.space(2)
      }
      PanelSeparator {
        visible: settingRow.isHeading
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: settingLabel.right
        anchors.leftMargin: Style.space(8)
        anchors.right: parent.right
        foreground: page.widget.foreground
        height: Style.space(2)
      }

      // Single-boolean toggle rows (store options and General options) share
      // the same control column as dropdowns and inputs.
      Row {
        anchors.left: parent.left
        anchors.leftMargin: page.widget.storeIndent
        anchors.verticalCenter: parent.verticalCenter
        spacing: page.widget.settingsGap
        visible: modelData.kind === "toggle"

        Text {
          width: page.widget.settingsLabelColumn
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: (modelData.label || "") + ":"
          color: page.widget.foreground
          font.family: page.widget.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        // Wrapped so the switch's cursor-ring inset does not push the visible
        // track right of the dropdown/input column below it.
        Item {
          width: generalToggle.implicitWidth - page.widget.settingsTogglePad
          height: generalToggle.implicitHeight
          anchors.verticalCenter: parent.verticalCenter

          ToggleSwitch {
            id: generalToggle
            x: -page.widget.settingsTogglePad
            anchors.verticalCenter: parent.verticalCenter
            checked: page.widget.settingsToggleChecked(modelData)
            foreground: page.widget.foreground
            accent: Commons.Color.accent
            onToggled: page.widget.settingsToggleFlip(modelData)
          }
        }
      }

      // Condensed store row: Enabled and Notifications on one line, each
      // control at a fixed column so the two switch stacks line up down the
      // whole page.
      Row {
        anchors.left: parent.left
        anchors.leftMargin: page.widget.storeIndent
        anchors.verticalCenter: parent.verticalCenter
        spacing: page.widget.settingsGap
        visible: modelData.kind === "store"

        Text {
          width: page.widget.settingsStoreLabel1
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "Enabled:"
          color: page.widget.foreground
          font.family: page.widget.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        ToggleSwitch {
          anchors.verticalCenter: parent.verticalCenter
          checked: page.widget.storesOn[modelData.store] === true
          foreground: page.widget.foreground
          accent: Commons.Color.accent
          onToggled: page.widget.toggleStore(modelData.store)
        }
        Item {
          width: page.widget.settingsCol2X
            - page.widget.settingsStoreLabel1 - page.widget.settingsGap
            - page.widget.settingsToggleWidth - page.widget.settingsGap
        }
        Text {
          width: page.widget.settingsStoreLabel2
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "Notifications:"
          color: page.widget.foreground
          font.family: page.widget.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        ToggleSwitch {
          anchors.verticalCenter: parent.verticalCenter
          checked: page.widget.notifyOn[modelData.store] === true
          foreground: page.widget.foreground
          accent: Commons.Color.accent
          onToggled: page.widget.toggleBell(modelData.store)
        }
      }

      // Epic platforms row: Android and iOS on one line, in the same two
      // columns as Enabled and Notifications above it.
      Row {
        anchors.left: parent.left
        anchors.leftMargin: page.widget.storeIndent
        anchors.verticalCenter: parent.verticalCenter
        spacing: page.widget.settingsGap
        visible: modelData.kind === "platforms"

        Text {
          width: page.widget.settingsStoreLabel1
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "Android:"
          color: page.widget.foreground
          font.family: page.widget.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        ToggleSwitch {
          anchors.verticalCenter: parent.verticalCenter
          checked: page.widget.epicMobileOn.android === true
          foreground: page.widget.foreground
          accent: Commons.Color.accent
          onToggled: page.widget.toggleEpicMobile("android")
        }
        Item {
          width: page.widget.settingsCol2X
            - page.widget.settingsStoreLabel1 - page.widget.settingsGap
            - page.widget.settingsToggleWidth - page.widget.settingsGap
        }
        Text {
          width: page.widget.settingsStoreLabel2
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "iOS:"
          color: page.widget.foreground
          font.family: page.widget.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        ToggleSwitch {
          anchors.verticalCenter: parent.verticalCenter
          checked: page.widget.epicMobileOn.ios === true
          foreground: page.widget.foreground
          accent: Commons.Color.accent
          onToggled: page.widget.toggleEpicMobile("ios")
        }
      }

      // Sensible dropdown for both ranged settings, with a Custom entry that
      // reveals a numeric-only input for schema-valid values between presets.
      Row {
        id: rangeRow
        anchors.left: parent.left
        anchors.leftMargin: page.widget.storeIndent
        anchors.verticalCenter: parent.verticalCenter
        spacing: page.widget.settingsGap
        visible: modelData.kind === "sliderRefresh" || modelData.kind === "sliderNotify"

        readonly property bool isRefresh: modelData.kind === "sliderRefresh"
        readonly property int currentValue: isRefresh
          ? page.widget.refreshMinutes : page.widget.maxStoreNotifications
        readonly property var presets: isRefresh
          ? [30, 45, 60, 90, 120, 240, 360]
          : [0, 1, 2, 3, 4, 5]
        readonly property bool isPreset: presets.indexOf(currentValue) >= 0
        readonly property string syncedValue: isPreset ? String(currentValue) : "custom"

        Text {
          width: page.widget.settingsLabelColumn
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: rangeRow.isRefresh
            ? "Refresh interval (min):" : "Store notification limit:"
          color: page.widget.foreground
          font.family: page.widget.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Dropdown {
          id: rangeDropdown
          width: page.widget.settingsControlWidth
          label: ""
          showLabel: false
          property bool userChoseCustom: false
          readonly property bool customSelected: userChoseCustom || !rangeRow.isPreset
          value: userChoseCustom ? "custom" : rangeRow.syncedValue
          options: rangeRow.isRefresh
            ? [{ value: "30", label: "30m" }, { value: "45", label: "45m" },
               { value: "60", label: "1h" }, { value: "90", label: "1.5h" },
               { value: "120", label: "2h" }, { value: "240", label: "4h" },
               { value: "360", label: "6h" },
               { value: "custom", label: "Custom" }]
            : [{ value: "0", label: "No limit" }, { value: "1", label: "1" },
               { value: "2", label: "2" }, { value: "3", label: "3" },
               { value: "4", label: "4" }, { value: "5", label: "5" },
               { value: "custom", label: "Custom" }]
          foreground: page.widget.foreground
          fontFamily: page.widget.fontFamily

          function resyncValue() {
            rangeDropdown.value = Qt.binding(function() {
              return rangeDropdown.userChoseCustom ? "custom" : rangeRow.syncedValue
            })
          }

          onChanged: {
            if (value === "custom") {
              rangeDropdown.userChoseCustom = true
            } else {
              rangeDropdown.userChoseCustom = false
              if (rangeRow.isRefresh)
                page.widget.persist({ refreshMinutes: Model.normalizeRefreshMinutes(Number(value)) })
              else
                page.widget.persist({ maxStoreNotifications: Model.normalizeMaxStoreNotifications(Number(value)) })
            }
            resyncValue()
          }

          Connections {
            target: rangeRow
            function onCurrentValueChanged() {
              if (rangeRow.isPreset) rangeDropdown.userChoseCustom = false
              rangeDropdown.resyncValue()
            }
          }
        }

        EntryField {
          id: customField
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(52)
          height: Style.spacing.controlHeight
          verticalPadding: Style.spacing.controlPaddingY
          visible: rangeDropdown.customSelected
          text: String(rangeRow.currentValue)
          fontFamily: page.widget.fontFamily
          foreground: page.widget.foreground
          accent: Commons.Color.accent
          python: page.widget.python
          cappedRun: page.widget.cappedRun
          // Three digits cover the highest preset and the schema maximum.
          maximumLength: 3
          placeholderText: rangeRow.isRefresh ? "30–720" : "0–20"
          // A whole number of minutes or games: a letter never enters the
          // field, so there is nothing to reject on commit.
          acceptInput: function(value) { return /^[0-9]*$/.test(value) }
          onActiveFocusChanged: page.widget.noteEditor(customField, activeFocus)
          onCancelled: {
            text = Qt.binding(function() { return String(rangeRow.currentValue) })
            if (rangeRow.isPreset) {
              rangeDropdown.userChoseCustom = false
              rangeDropdown.resyncValue()
            }
            page.widget.leaveEditor(customField)
          }
          onEditingFinished: function(explicit) {
            var raw = String(text).trim()
            if (/^\d+$/.test(raw)) {
              var n = Number(raw)
              if (rangeRow.isRefresh)
                page.widget.persist({ refreshMinutes: Model.normalizeRefreshMinutes(n) })
              else
                page.widget.persist({ maxStoreNotifications: Model.normalizeMaxStoreNotifications(n) })
              text = Qt.binding(function() { return String(rangeRow.currentValue) })
              if (rangeRow.isPreset) {
                rangeDropdown.userChoseCustom = false
                rangeDropdown.resyncValue()
              }
            } else if (explicit) {
              // Empty or invalid text on explicit finish reverts to saved value;
              // implicit focus loss (e.g. clipboard picker opening mid-edit)
              // leaves the draft alone so a paste can land cleanly.
              text = Qt.binding(function() { return String(rangeRow.currentValue) })
              if (rangeRow.isPreset) {
                rangeDropdown.userChoseCustom = false
                rangeDropdown.resyncValue()
              }
            }
            // Only an explicit finish hands the keyboard back to the panel.
            // Losing the focus to something else, or another window taking the
            // keyboard, leaves the field holding it.
            if (explicit) page.widget.leaveEditor(customField)
          }
        }
      }

      EntryField {
        id: countryField
        anchors.left: parent.left
        anchors.leftMargin: page.widget.storeIndent + page.widget.settingsLabelColumn
          + page.widget.settingsGap
        anchors.verticalCenter: parent.verticalCenter
        // The same width as the dropdowns above it, so the controls in the
        // page share one column.
        width: page.widget.settingsControlWidth
        height: Style.spacing.controlHeight
        visible: modelData.kind === "country"
        text: page.widget.country
        placeholderText: "e.g. US"
        fontFamily: page.widget.fontFamily
        foreground: page.widget.foreground
        accent: Commons.Color.accent
        python: page.widget.python
        cappedRun: page.widget.cappedRun
        // ISO 3166-1 alpha-2 is two letters. Anything else is dropped as it is
        // typed or pasted, so a stray digit never reaches the setting and the
        // value is upper-cased on the way in.
        maximumLength: 2
        sanitize: function(value) { return Model.countryInput(value) }
        acceptInput: function(value) { return /^[A-Z]*$/.test(value) }
        onActiveFocusChanged: page.widget.noteEditor(countryField, activeFocus)
        onCancelled: {
          text = Qt.binding(function() { return page.widget.country })
          page.widget.leaveEditor(countryField)
        }
        onEditingFinished: function(explicit) {
          var raw = String(text).trim()
          // On implicit focus loss (such as a clipboard picker taking focus
          // mid-edit), only commit a complete two-letter code; leave empty or
          // half-typed drafts untouched so a paste can land cleanly.
          if (!explicit && raw.length !== 2) return
          if (raw.length === 0 || raw.length === 2) {
            var clean = Model.normalizeCountry(raw)
            if (clean !== page.widget.country) {
              page.widget.persist({ country: clean })
              page.widget.onCountryUpdated()
            }
          }
          text = Qt.binding(function() { return page.widget.country })
          // Only an explicit finish hands the keyboard back to the panel.
          if (explicit) page.widget.leaveEditor(countryField)
        }
      }
    }
  }

  // Edge scroll hints for the settings list when it overflows.
  Rectangle {
    id: settingsTopFade
    anchors.top: settingsList.top
    anchors.left: settingsList.left
    anchors.right: settingsList.right
    height: Style.space(30)
    visible: page.visible && settingsList.interactive && !settingsList.atYBeginning
    z: 2
    gradient: Gradient {
      GradientStop { position: 0.0; color: Commons.Color.popups.background }
      GradientStop {
        position: 1.0
        color: Qt.rgba(Commons.Color.popups.background.r,
                       Commons.Color.popups.background.g,
                       Commons.Color.popups.background.b, 0)
      }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Style.space(2)
      text: "\u{F077}"
      textFormat: Text.PlainText
      color: page.widget.dim
      font.family: page.widget.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Rectangle {
    id: settingsBottomFade
    anchors.bottom: settingsList.bottom
    anchors.left: settingsList.left
    anchors.right: settingsList.right
    height: Style.space(30)
    visible: page.visible && settingsList.interactive && !settingsList.atYEnd
    z: 2
    gradient: Gradient {
      GradientStop {
        position: 0.0
        color: Qt.rgba(Commons.Color.popups.background.r,
                       Commons.Color.popups.background.g,
                       Commons.Color.popups.background.b, 0)
      }
      GradientStop { position: 1.0; color: Commons.Color.popups.background }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(2)
      text: "\u{F078}"
      textFormat: Text.PlainText
      color: page.widget.dim
      font.family: page.widget.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Settings footer: a single centred button back to the store list.
  Column {
    id: settingsFooter
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.leftMargin: Style.spacing.sm
    anchors.rightMargin: Style.spacing.sm
    spacing: Style.space(6)
    topPadding: Style.space(8)

    PanelSeparator {
      id: settingsFooterRule
      width: parent.width
      foreground: page.widget.foreground
    }

    Item {
      width: parent.width
      implicitHeight: page.footerButtonHeight

      Button {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        text: "Exit Settings"
        bordered: true
        foreground: page.widget.footerInk
        accent: Commons.Color.accent
        fontFamily: page.widget.fontFamily
        fontSize: Style.font.caption
        tooltipText: "Back to the store list"
        onClicked: page.widget.exitSettings()
      }
    }
  }
}
