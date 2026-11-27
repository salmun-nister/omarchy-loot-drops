pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
// Qt 6.12 added its own `Color` singleton to QtQuick, which shadows the
// unqualified name the theme palette is read through. Every palette lookup here
// is therefore written as `Commons.Color.*`, so colours keep resolving on 6.12
// instead of falling back to black. Do not shorten these back to `Color`.
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Watch Steam, Epic, GOG and Amazon Luna for games that are free to keep.
// Parsing, URL allowlisting, seen-id transitions and notification copy live in
// Model.js; this file owns transport, persistence and rendering.
//
// The bar widget is always loaded, so it owns the refresh timer itself. There
// is deliberately no service kind: a process-wide singleton would be a second
// owner of the same timer for no gain.
Panel {
  id: root
  moduleName: "salmun-nister.loot-drops"
  ipcTarget: Model.IPC_TARGET
  manageIpc: false

  readonly property string stateDir:
    Quickshell.env("LOOT_DROPS_STATE")
    || ((Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
        + "/salmun-nister.loot-drops")

  // The interpreter is named absolutely rather than taken from PATH: a user
  // with a version manager on PATH would otherwise run the helpers under a
  // different Python than the one they were tested on.
  readonly property string python: "/usr/bin/python3"

  // Helpers are addressed through the shell so a symlinked plugin directory
  // resolves to its real path, matching how the bar launches them.
  readonly property string cappedRun: pluginFile("lib/capped-run")
  readonly property string seenStatePath: pluginFile("lib/seen-state")

  // curl is told to give up at this deadline, and a fetch that overruns exits
  // non-zero, which the per-store onExited turns into an unreachable store. A
  // QML-side timer was tried and removed: the widget's Process is not a process
  // group leader, so it cannot signal its own child safely. See DESIGN.md.
  readonly property int fetchDeadlineMs: 20000

  function pluginFile(relative) {
    var url = String(Qt.resolvedUrl(relative))
    if (url.indexOf("file://") === 0) url = url.slice(7)
    return decodeURIComponent(url)
  }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The store marks and the gutter they occupy. `heading` is the theme's 16px
  // token, so the marks follow a theme's font scale; labels and game titles
  // share the indent derived from it so the two levels stay aligned.
  readonly property int markSize: Style.font.heading
  readonly property int storeIndent: Style.spacing.sm + markSize + Style.space(8)

  // Settings geometry. Every row uses the same label→control gap, and the
  // controls sit on shared columns so switches, dropdowns and inputs line
  // up down the page.
  readonly property int settingsGap: Style.space(6)
  readonly property int settingsStoreLabel1: Style.space(56)
  readonly property int settingsStoreLabel2: Style.space(92)
  readonly property int settingsCol2X: Style.space(170)
  readonly property int settingsLabelColumn: Style.space(170)
  readonly property int settingsToggleWidth: Style.space(54)
  // ToggleSwitch draws its track inset by cursorPad so the hover ring fits
  // inside its own bounds; shifting the switch left by that inset lands the
  // track's left edge on the shared control column.
  readonly property int settingsTogglePad: Style.space(6)
  readonly property int settingsControlWidth: Style.space(96)

  // Which Settings field, if any, is taking keys. The panel's key catcher runs
  // before its children, so it must stand aside while a field is being edited
  // or typing would drive the panel instead of the field.
  property Item activeEditor: null
  function noteEditor(field, focused) {
    if (focused) root.activeEditor = field
    else if (root.activeEditor === field) root.activeEditor = null
  }
  // Return the keyboard to the panel unless another field has taken it. A
  // click straight from one field into the other must not pull focus back.
  // Only an explicit finish (Enter, Tab, Escape) comes through here: a field
  // that merely lost the focus keeps it, so the clipboard picker can close
  // and paste into it with Shift+Insert.
  function leaveEditor(field) {
    Qt.callLater(function() {
      if (root.activeEditor && root.activeEditor !== field) return
      keyCatcher.forceActiveFocus()
    })
  }

  readonly property var storesOn: Model.enabled({
    "steamEnabled": setting("steamEnabled", true),
    "epicEnabled": setting("epicEnabled", true),
    "gogEnabled": setting("gogEnabled", true),
    "amazonEnabled": setting("amazonEnabled", false)
  })
  readonly property var notifyOn: Model.notifyFor({
    "steamNotify": setting("steamNotify", true),
    "epicNotify": setting("epicNotify", true),
    "gogNotify": setting("gogNotify", true),
    "amazonNotify": setting("amazonNotify", true)
  })

  readonly property var epicMobileOn: ({
    "android": setting("epicMobileAndroid", false),
    "ios": setting("epicMobileIos", false)
  })
  readonly property int refreshMinutes:
    // undefined, not 0: an absent setting must land on the default, and 0 would
    // clamp to the floor instead.
    Model.normalizeRefreshMinutes(setting("refreshMinutes", undefined))
  // Per store, how many new games may notify individually before that store's
  // new games are bundled into one summary. 0 means no cap.
  readonly property int maxStoreNotifications:
    Model.normalizeMaxStoreNotifications(setting("maxStoreNotifications", undefined))
  readonly property string country: Model.countrySetting(root.settings)
  // Whether the panel hides games already marked seen. This is a view filter,
  // not a second baseline: the seen state itself is untouched.
  readonly property bool hideSeen: setting("hideSeen", false)
  readonly property bool endingSoonNotify: setting("endingSoonNotify", false)
  readonly property bool steamUseClient: setting("steamUseClient", false)
  readonly property bool epicHideAddOns: setting("epicHideAddOns", false)
  readonly property bool epicShowUpcoming: setting("epicShowUpcoming", false)

  // Per-store results. Each bucket keeps its own games, error, retry schedule,
  // and timestamp so one store failing never blanks or delays the others.
  property var buckets: ({
    "steam": newBucket(),
    "epic": newBucket(),
    "gog": newBucket(),
    "amazon": newBucket()
  })

  property var seenState: Model.emptySeen()
  property bool seenLoaded: false
  property bool seenSavePending: false
  property bool anyBusy: false
  // Epic assembly buffer: the PC catalog and the Android/iOS discover feeds
  // are fetched by separate processes so one slow or failing feed cannot
  // delay or blank the others. Parts are stashed here and only merged by
  // checkEpicAssembly() once every expected part has answered.
  property var epicParts: null
  property bool epicRefetchPending: false
  property double lastSuccessAt: 0
  property double nowMs: Date.now()
  property bool cursorActive: false
  property int selectedIndex: 0
  // The game row the pointer is over, as a flat list index, or -1 when the
  // pointer is off the rows. The highlight follows the most recent input: a
  // hover claims it and dismisses the keyboard cursor, and a keyboard move
  // claims it back. Only one row is ever highlighted.
  property int pointerIndex: -1
  // Where the pointer last was, in scene coordinates. A row sliding under a
  // still pointer reports the same scene point; only a changed point means the
  // mouse itself moved.
  property point lastPointerScene: Qt.point(-1, -1)
  // Which store the pointer or cursor last touched.
  property string targetStore: ""
  // Temporary footer feedback shown after copying a game link.
  property string copyFeedbackText: ""
  // One-line summary of disabled stores, for the footer. Empty when all
  // stores are on or every store is off (the all-off message stands alone).
  readonly property string disabledSummary: {
    if (Model.activeStores(storesOn).length === 0) return ""
    var names = []
    for (var i = 0; i < Model.STORES.length; i++) {
      var s = Model.STORES[i]
      if (storesOn[s] !== true) names.push(Model.STORE_SHORT[s] || Model.STORE_LABELS[s] || s)
    }
    if (names.length === 0) return ""
    var sentence = names.join(", ")
    if (names.length === 2)
      sentence = names[0] + " and " + names[1]
    else if (names.length > 2)
      sentence = names.slice(0, names.length - 1).join(", ") + ", and "
        + names[names.length - 1]
    // A long roster would wrap past the centred footer stack; the short
    // fallback carries the same meaning in one line.
    if (sentence.length > 38) return "Multiple stores are disabled"
    return sentence + (names.length === 1 ? " is disabled" : " are disabled")
  }
  // Whether the panel is currently showing the keyboard shortcuts.
  property bool showShortcuts: false
  // Whether the panel is showing the in-panel settings page instead of the
  // store list.
  property bool showSettings: false
  // Hover claims are suppressed briefly after a toggle reshapes the list,
  // so a row sliding under a still pointer cannot steal the highlight for
  // a frame before the layout settles.
  property double hoverSuppressUntil: 0

  // Stale tracks the refresh interval, so it stays meaningful however often the
  // stores are being polled.
  readonly property int staleAfter: Model.staleAfterMs(refreshMinutes)
  readonly property bool stale: lastSuccessAt > 0
    && nowMs - lastSuccessAt >= staleAfter
  // The footer's ink, shared by the freshness text and buttons so the two
  // cannot drift apart. The text drops to `dim` once the data is stale; the
  // buttons deliberately hold this colour, so they stay equally usable when the
  // numbers behind them are old.
  readonly property color footerInk: Qt.darker(foreground, 1.5)
  readonly property string freshness: Model.freshnessLabel(
    lastSuccessAt, nowMs, anyBusy, staleAfter)
  readonly property var activeStores: Model.activeStores(storesOn)
  readonly property var visibleGames: visibleGameList()
  // How many rows the panel's ListView actually instantiated.
  readonly property int renderedRows: panelList.count

  // Whether any enabled store currently has a retry scheduled. Drives the 5s
  // retry tick timer so it stays idle when all stores are healthy.
  readonly property bool hasPendingRetries: {
    for (var i = 0; i < Model.STORES.length; i++) {
      var s = Model.STORES[i]
      if (storesOn[s] === true && bucket(s).retryAt > 0) return true
    }
    return false
  }

  function listMetrics() {
    return {
      count: panelList.count,
      contentHeight: panelList.contentHeight,
      height: panelList.height,
      pinnedHeight: pinned.height,
      pinnedBottom: pinned.y + pinned.height,
      listY: panelList.y,
      listBottom: panelList.y + panelList.height,
      footerY: panelFooter.y,
      footerHeight: panelFooter.height
    }
  }

  function rowsLaidOut() {
    var m = listMetrics()
    if (m.count === 0) return false
    return m.contentHeight > 0 && m.height > 0
  }

  // Whether an enabled store has any game at all. This reads the buckets rather
  // than the filtered rows, so hiding seen games cannot make the mark look
  // empty while the store still has something.
  readonly property bool hasGames: Model.totalGames(enabledBuckets()) > 0

  // Games on offer that the user has not acknowledged yet. Independent of
  // notifications: a muted store still has something you have not looked at.
  // Only enabled stores count, because a switched-off store's rows are hidden
  // and its markers could never be cleared from the panel.
  readonly property bool hasUnseen: Model.hasUnseen(seenState, enabledBuckets())

  function newBucket() {
    return {
      games: [],
      upcoming: [],
      error: "",
      busy: false,
      neverChecked: true,
      lastSuccessAt: 0,
      retryDelayMs: 30000,
      retryAt: 0
    }
  }

  function setBucket(store, fields) {
    var next = {}
    for (var key in buckets) next[key] = buckets[key]
    var bucket = newBucket()
    var current = buckets[store]
    for (var k in current) bucket[k] = current[k]
    for (var f in fields) bucket[f] = fields[f]
    next[store] = bucket
    buckets = next
  }

  function bucket(store) {
    return buckets[store] || newBucket()
  }

  // The per-store results the panel actually shows, i.e. only the stores that
  // are switched on. The bar dot and the row markers both key off this so a
  // hidden store can neither light the dot nor hold it on.
  function enabledBuckets() {
    var out = {}
    for (var i = 0; i < Model.STORES.length; i++) {
      var store = Model.STORES[i]
      if (storesOn[store] === true) {
        var b = bucket(store)
        out[store] = {
          games: visibleGamesFor(store),
          error: b.error,
          busy: b.busy,
          neverChecked: b.neverChecked,
          lastSuccessAt: b.lastSuccessAt
        }
      }
    }
    return out
  }

  // Which ids the user has acknowledged, per store, as a lookup. The row
  // marker reads this rather than a per-row flag carried in the list model: a
  // changed model would rebuild every delegate and drop the scroll position
  // each time a game is marked, whereas this re-evaluates only the markers.
  readonly property var acknowledgedIds: acknowledgedIndex()

  function acknowledgedIndex() {
    var index = {}
    for (var i = 0; i < Model.STORES.length; i++) {
      var ids = Model.acknowledgedOf(seenState, Model.STORES[i])
      var set = {}
      for (var a = 0; a < ids.length; a++) set[ids[a]] = true
      index[Model.STORES[i]] = set
    }
    return index
  }

  function gameUnseen(store, id) {
    var set = acknowledgedIds[store]
    return !(set && set[id])
  }

  // True when the hover position differs enough from the previous one to be the
  // pointer moving, rather than a row scrolling underneath a still pointer.
  function pointerMoved(scenePoint) {
    var threshold = Style.space(4)
    var moved = lastPointerScene.x < 0
      || Math.abs(scenePoint.x - lastPointerScene.x) >= threshold
      || Math.abs(scenePoint.y - lastPointerScene.y) >= threshold
    lastPointerScene = scenePoint
    return moved
  }

  // Flat, store-ordered list of row entries. Deliberately does NOT read
  // `nowMs` so the 30-second clock tick never rebuilds the ListView model or
  // resets the user's scroll position; time-sensitive labels read `root.nowMs`
  // inside each delegate instead.
  function visibleGameList() {
    var list = []
    var anyEnabled = false
    for (var i = 0; i < Model.STORES.length; i++) {
      var store = Model.STORES[i]
      var on = storesOn[store] === true
      if (on) anyEnabled = true
      var current = bucket(store)
      // Unseen first, then seen: the rows that still need action always
      // read above the muted ones, whichever arrival order they came in.
      var acknowledged = Model.acknowledgedOf(seenState, store)
      var acked = {}
      for (var a = 0; a < acknowledged.length; a++) acked[acknowledged[a]] = true
      var ordered = []
      var seenGames = []
      var all = visibleGamesFor(store)
      for (var g = 0; g < all.length; g++) {
        if (acked[all[g] && all[g].id]) seenGames.push(all[g])
        else ordered.push(all[g])
      }
      ordered = ordered.concat(seenGames)
      var shown = ordered
      var hidden = 0
      if (hideSeen) {
        var split = Model.splitSeenGames(ordered,
          Model.acknowledgedOf(seenState, store))
        shown = split.shown
        hidden = split.hidden
      }
      var upcoming = (store === "epic" && epicShowUpcoming && Array.isArray(current.upcoming))
        ? (epicHideAddOns ? Model.filterEpicAddOns(current.upcoming, true) : current.upcoming)
        : []
      // A store gets a section when it is watched and has games, hidden-seen
      // rows, upcoming rows, a fetch in flight, or an error to report.
      var hasEntries = on && (shown.length > 0 || hidden > 0 || upcoming.length > 0 || current.busy)
      var failed = on && !!current.error
      if (!hasEntries && !failed) continue
      list.push({
        kind: "header",
        store: store,
        errorLabel: Model.storeErrorLabel(store, errorsByStore())
      })
      // A store with nothing yet but a fetch in flight says so, instead
      // of sitting empty while the network catches up.
      if (shown.length === 0 && hidden === 0 && upcoming.length === 0 && current.busy) {
        list.push({ kind: "checking", store: store })
      }
      for (var j = 0; j < shown.length; j++) {
        list.push({ kind: "game", store: store, game: shown[j] })
      }
      // The summary follows the live games; its ending-soon count is evaluated
      // against root.nowMs in the delegate from hiddenEndsAt.
      if (hidden > 0) {
        var hiddenEndsAt = []
        for (var s = 0; s < seenGames.length; s++) {
          if (seenGames[s] && seenGames[s].endsAt) hiddenEndsAt.push(seenGames[s].endsAt)
        }
        list.push({ kind: "hidden", store: store, count: hidden, hiddenEndsAt: hiddenEndsAt })
      }
      for (var u = 0; u < upcoming.length; u++) {
        list.push({ kind: "upcoming", store: store, game: upcoming[u] })
      }
    }
    if (anyEnabled && list.length === 0 && !anyBusy) list.push({ kind: "empty" })
    return list
  }

  // Write a setting change back to this widget's entry in shell.json. Applied
  // locally first via root.settings so controls respond on the click itself,
  // then flushed when the panel closes (or after the debounce safety net).
  function persist(patch) {
    var entry = { id: root.moduleName }
    var current = root.settings
    if (current && typeof current === "object") {
      for (var k in current) {
        if (k !== "id") entry[k] = current[k]
      }
    }
    for (var p in patch) entry[p] = patch[p]
    root.settings = entry
    pendingEntry = entry
    persistDebounce.restart()
  }

  property var pendingEntry: null

  function flushPersist() {
    if (!pendingEntry) return
    var entry = pendingEntry
    pendingEntry = null
    if (root.bar && root.bar.shell
        && typeof root.bar.shell.updateEntryInline === "function") {
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    }
  }

  // One-time copy of the pre-Epic country key.
  onBarChanged: migrateCountry()
  onSettingsChanged: migrateCountry()

  function migrateCountry() {
    var patch = Model.countryPatch(root.settings)
    if (!patch) return
    if (!root.bar || !root.bar.shell
        || typeof root.bar.shell.updateEntryInline !== "function") return
    persist(patch)
  }

  function exitSettings() {
    root.showSettings = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function enabledKey(store) { return store + "Enabled" }
  function notifyKey(store) { return store + "Notify" }

  // A mobile game is hidden the moment its platform toggle is off, without
  // waiting for a re-fetch: the feeds already landed in the bucket, and only
  // the view needs to drop them. Only Epic rows carry a platform.
  function platformHidden(platform) {
    if (platform === "android") return epicMobileOn.android !== true
    if (platform === "ios") return epicMobileOn.ios !== true
    return false
  }

  function visibleGamesFor(store) {
    var games = bucket(store).games || []
    var out = []
    for (var i = 0; i < games.length; i++) {
      var game = games[i]
      if (!game) continue
      if (platformHidden(game.platform)) continue
      if (store === "epic" && epicHideAddOns && game.isAddOn === true) continue
      out.push(game)
    }
    return out
  }

  // The settings page as a flat row model: a heading then switch rows per
  // store, then a general section.
  function settingsRows() {
    var rows = []
    for (var i = 0; i < Model.STORES.length; i++) {
      var store = Model.STORES[i]
      rows.push({ kind: "heading", label: Model.STORE_LABELS[store] || store, store: store })
      rows.push({ kind: "store", label: "", store: store })
      if (store === "steam") {
        rows.push({ kind: "toggle", label: "Open in Steam client",
                    setting: "steamUseClient", store: store, what: "steamUseClient" })
      } else if (store === "epic") {
        rows.push({ kind: "platforms", label: "", store: store })
        rows.push({ kind: "toggle", label: "Hide add-ons / DLC",
                    setting: "epicHideAddOns", store: store, what: "epicHideAddOns" })
        rows.push({ kind: "toggle", label: "Show upcoming games",
                    setting: "epicShowUpcoming", store: store, what: "epicShowUpcoming" })
      }
    }
    rows.push({ kind: "heading", label: "General" })
    rows.push({ kind: "toggle", label: "Hide seen games",
                setting: "hideSeen", store: "", what: "hideSeen" })
    rows.push({ kind: "toggle", label: "Ending soon reminders",
                setting: "endingSoonNotify", store: "", what: "endingSoonNotify" })
    rows.push({ kind: "sliderRefresh", label: "Refresh interval" })
    rows.push({ kind: "sliderNotify", label: "Store notification limit" })
    rows.push({ kind: "country", label: "Store country" })
    return rows
  }

  function settingsToggleChecked(entry) {
    if (!entry) return false
    if (entry.what === "hideSeen") return hideSeen
    if (entry.what === "endingSoonNotify") return endingSoonNotify
    if (entry.what === "steamUseClient") return steamUseClient
    if (entry.what === "epicHideAddOns") return epicHideAddOns
    if (entry.what === "epicShowUpcoming") return epicShowUpcoming
    return false
  }

  function settingsToggleFlip(entry) {
    if (!entry) return
    if (entry.what === "hideSeen") {
      toggleHideSeen()
    } else if (entry.what === "endingSoonNotify") {
      var next = !endingSoonNotify
      persist({ endingSoonNotify: next })
      if (next) checkEndingSoonReminders()
    } else if (entry.what === "steamUseClient") {
      persist({ steamUseClient: !steamUseClient })
    } else if (entry.what === "epicHideAddOns") {
      snapPanelHeight()
      persist({ epicHideAddOns: !epicHideAddOns })
      resetSelectionAfterToggle()
    } else if (entry.what === "epicShowUpcoming") {
      snapPanelHeight()
      persist({ epicShowUpcoming: !epicShowUpcoming })
      resetSelectionAfterToggle()
    }
  }

  // Country changes affect Steam and Epic listings; re-prime them silently and
  // re-fetch immediately so regional offers update without spurious alerts.
  function onCountryUpdated() {
    if (!seenLoaded) return
    var unprimed = false
    if (storesOn.steam === true) {
      seenState = Model.unprimeStore(seenState, "steam")
      unprimed = true
    }
    if (storesOn.epic === true) {
      seenState = Model.unprimeStore(seenState, "epic")
      unprimed = true
    }
    if (unprimed) persistSeen()
    if (storesOn.steam === true && !bucket("steam").busy) startFetch("steam")
    if (storesOn.epic === true) {
      if (bucket("epic").busy) epicRefetchPending = true
      else startFetch("epic")
    }
  }

  function displayBuckets() {
    return enabledBuckets()
  }

  // Switching a store off stops it being fetched at all; switching it back on
  // re-records silently rather than announcing everything it missed.
  function toggleStore(store) {
    targetStore = store
    suppressHover()
    var turningOn = storesOn[store] !== true
    persist({ [enabledKey(store)]: turningOn })
    if (!turningOn) {
      setBucket(store, { retryAt: 0, retryDelayMs: 30000 })
    }
    if (turningOn && seenLoaded) {
      seenState = Model.unprimeStore(seenState, store)
      persistSeen()
    }
    reanchorCursor()
    if (turningOn && !bucket(store).busy) startFetch(store)
  }

  function toggleBell(store) {
    targetStore = store
    persist({ [notifyKey(store)]: notifyOn[store] !== true })
  }

  function suppressHover() {
    hoverSuppressUntil = Date.now() + 1000
    cursorActive = false
    pointerIndex = -1
    selectedIndex = -1
    lastPointerScene = Qt.point(-1, -1)
  }

  function resetSelectionAfterToggle() {
    suppressHover()
  }

  function epicMobileKey(platform) {
    return platform === "ios" ? "epicMobileIos" : "epicMobileAndroid"
  }

  function toggleEpicMobile(platform) {
    if (Model.PLATFORMS.indexOf(platform) < 0) return
    var turningOn = epicMobileOn[platform] !== true
    snapPanelHeight()
    suppressHover()
    persist({ [epicMobileKey(platform)]: turningOn })
    // Epic's mobile feeds share the epic baseline, so enabling one has to
    // re-prime that store as well; otherwise its currently free games would
    // arrive as a burst of "new" notifications.
    if (turningOn && seenLoaded) {
      seenState = Model.unprimeStore(seenState, "epic")
      persistSeen()
    }
    resetSelectionAfterToggle()
    if (turningOn && storesOn.epic === true) {
      if (bucket("epic").busy) epicRefetchPending = true
      else startFetch("epic")
    }
  }

  // The eye hides games the user has already marked seen.
  function toggleHideSeen() {
    snapPanelHeight()
    persist({ hideSeen: !hideSeen })
    resetSelectionAfterToggle()
  }

  // KeyboardPanel animates drawnHeight whenever it changes while live
  // (200ms), even for a deliberate show/hide toggle that should be instant.
  function snapPanelHeight() {
    if (panel) panel.heightLive = false
  }

  function errorsByStore() {
    var out = {}
    for (var i = 0; i < Model.STORES.length; i++) {
      var store = Model.STORES[i]
      var error = bucket(store).error
      if (error) out[store] = { message: error }
    }
    return out
  }

  function hasStoreError() {
    for (var i = 0; i < Model.STORES.length; i++) {
      var store = Model.STORES[i]
      if (storesOn[store] === true && bucket(store).error) return true
    }
    return false
  }

  // Acknowledge one game, clearing its marker and letting the bar dot go out
  // once every new game has been marked. Only moves/scrolls the keyboard cursor
  // when the keyboard cursor is actually active.
  function markSeen(store, id) {
    if (!seenLoaded) return
    var key = store + ":" + id
    var prevPos = cursorActive ? gameRowIndexes().indexOf(selectedIndex) : -1
    seenState = Model.acknowledgeGame(seenState, store, id)
    persistSeen()
    if (cursorActive) setCursorById(key, prevPos)
  }

  // Mark every currently visible game across enabled stores as seen.
  function markAllSeen() {
    if (!seenLoaded || !hasUnseen) return
    var key = cursorActive ? keepSelectedId() : ""
    seenState = Model.acknowledgeAll(seenState, enabledBuckets())
    persistSeen()
    if (hideSeen) resetSelectionAfterToggle()
    else if (cursorActive) setCursorById(key)
  }

  // The game the highlight is on, keyboard or pointer.
  function highlightedGame() {
    if (cursorActive) return selectedGame()
    if (pointerIndex >= 0 && pointerIndex < visibleGames.length) {
      var row = visibleGames[pointerIndex]
      if (row && row.kind === "game") return row
    }
    return null
  }

  // Flip a game's seen state: an unseen game is acknowledged, a seen one is
  // forgotten and its marker comes back.
  function toggleSeen(store, id) {
    if (!seenLoaded) return
    var key = store + ":" + id
    var prevPos = cursorActive ? gameRowIndexes().indexOf(selectedIndex) : -1
    seenState = gameUnseen(store, id)
      ? Model.acknowledgeGame(seenState, store, id)
      : Model.forgetGame(seenState, store, id)
    persistSeen()
    if (cursorActive) setCursorById(key, prevPos)
  }

  function toggleHighlighted() {
    var row = highlightedGame()
    if (row) toggleSeen(row.store, row.game.id)
  }

  // Copy the highlighted game's allowlisted HTTPS store link (write-only
  // clipboard update; never reads the clipboard).
  function copyHighlightedUrl() {
    var row = highlightedGame()
    if (!row) return
    var url = Model.safeUrl(row.store, row.game.url) || Model.searchUrl(row.store)
    if (!url) return
    Quickshell.clipboardText = url
    copyFeedbackText = "Copied link"
    copyFeedbackTimer.restart()
  }

  function ingestSeen(raw) {
    if (seenLoaded) return
    seenState = Model.parseSeen(raw)
    seenLoaded = true
  }

  // Serialize and persist seen.json atomically. If a save is already running,
  // mark dirty so saveSeenProc.onExited immediately flushes the latest state.
  function persistSeen() {
    if (!seenLoaded) return
    if (saveSeenProc.running) {
      seenSavePending = true
      return
    }
    seenSavePending = false
    saveSeenProc.payload = Model.serializeSeen(seenState) + "\n"
    saveSeenProc.running = true
  }

  // Each enabled store is fetched by its own process, so a slow or hanging
  // store cannot delay the others and one failure cannot mask the rest.
  function refresh() {
    if (!seenLoaded) return
    for (var i = 0; i < Model.STORES.length; i++) {
      var store = Model.STORES[i]
      if (!storesOn[store]) {
        setBucket(store, { busy: false, retryAt: 0 })
        continue
      }
      if (bucket(store).busy) continue
      startFetch(store)
    }
    updateBusy()
  }

  function startFetch(store) {
    setBucket(store, { busy: true, retryAt: 0 })
    if (store === "epic") {
      beginEpicAssembly()
      return
    }
    var proc = fetchProcs[store]
    proc.start([root.python, root.cappedRun, String(Model.MAX_BYTES)]
      .concat(fetchArgs(store)))
    updateBusy()
  }

  // Start the PC catalog fetch plus whichever mobile platform feeds are
  // switched on. checkEpicAssembly() runs only after every expected part
  // answers, so a partial result is never shown as the whole Epic list.
  function beginEpicAssembly() {
    var parts = {
      pc: null,
      upcoming: [],
      android: null,
      ios: null,
      failed: 0,
      failedParts: { pc: false, android: false, ios: false },
      expected: 0
    }
    epicParts = parts
    var wanted = ["pc"]
    if (epicMobileOn.android === true) wanted.push("android")
    if (epicMobileOn.ios === true) wanted.push("ios")
    parts.expected = wanted.length
    for (var i = 0; i < wanted.length; i++) {
      var which = wanted[i]
      if (which === "pc") {
        epicProc.start([root.python, root.cappedRun, String(Model.MAX_BYTES)]
          .concat(fetchArgs("epic")))
      } else if (which === "android") {
        epicMobileAndroidProc.start([root.python, root.cappedRun, String(Model.MAX_BYTES)]
          .concat(fetchArgsMobile("android")))
      } else {
        epicMobileIosProc.start([root.python, root.cappedRun, String(Model.MAX_BYTES)]
          .concat(fetchArgsMobile("ios")))
      }
    }
    updateBusy()
  }

  function finishEpicPart(which, games, upcoming) {
    if (!epicParts || epicParts[which] !== null) return
    epicParts[which] = games || []
    if (which === "pc") epicParts.upcoming = upcoming || []
    checkEpicAssembly()
  }

  function failEpicPart(which) {
    if (!epicParts || epicParts[which] !== null) return
    epicParts[which] = []
    epicParts.failed++
    if (epicParts.failedParts) epicParts.failedParts[which] = true
    checkEpicAssembly()
  }

  function checkEpicAssembly() {
    if (!epicParts) return
    var result = Model.epicAssemblyResult(epicParts)
    if (!result) return
    epicParts = null
    if (result.mode === "partial") {
      // Show what answered, but do not move the baseline: the feed that failed
      // still has its ids recorded, so its games are not re-announced when it
      // comes back. Schedule a retry for Epic so the missing feed recovers.
      succeed("epic", result.games, false, result.upcoming)
      scheduleRetry("epic", result.errorLabel || "Could not reach some Epic feeds", true)
    } else if (result.mode === "fail") {
      fail("epic", result.errorLabel || "Could not reach Epic", true)
    } else {
      succeed("epic", result.games, true, result.upcoming)
    }
    if (epicRefetchPending) {
      epicRefetchPending = false
      if (storesOn.epic === true && !bucket("epic").busy) startFetch("epic")
    }
  }

  function fetchArgs(store) {
    // Amazon is rendered rather than requested, so a browser is its transport.
    if (store === "amazon") return amazonArgs()
    var deadlineSeconds = Math.ceil(fetchDeadlineMs / 1000)
    var args = [
      // Drop -f so HTTP 4xx/5xx deliver their status code via --write-out and
      // are classified cleanly by Model.httpResultAction without masking GOG's
      // healthy 404 or turning 5xx into a parse error.
      "curl", "-sS", "--max-time", String(deadlineSeconds),
      // --max-filesize is only honoured against a declared Content-Length, so
      // capped-run is what actually bounds a response that streams.
      "--max-filesize", String(Model.MAX_BYTES),
      "-A", Model.USER_AGENT,
      "-H", "Accept: application/json,text/html;q=0.9",
      // Steam's search endpoint only answers with JSON for an XHR.
      "-H", "X-Requested-With: XMLHttpRequest",
      "--write-out", "\n%{http_code}"
    ]
    if (store === "epic") {
      args.push("-H", "Content-Type: application/json",
        "--data", Model.epicQuery(country))
    }
    args.push(sourceUrl(store))
    return args
  }

  function amazonArgs() {
    var deadlineSeconds = Math.ceil(fetchDeadlineMs / 1000)
    return [
      "/usr/bin/timeout", "-k", "2", String(deadlineSeconds),
      "/usr/bin/chromium", "--headless", "--no-first-run", "--disable-logging",
      "--user-data-dir=" + stateDir + "/browser-profile",
      "--virtual-time-budget=10000",
      "--dump-dom",
      sourceUrl("amazon")
    ]
  }

  function sourceUrl(store) {
    if (store === "steam") {
      var filters = "sort_by=_ASC&hwtype=0&maxprice=free&category1=998"
        + "&supportedlang=english&specials=1"
      var url = "https://store.steampowered.com/search/results/?" + filters
        + "&query=&start=0&count=50&infinite=1&l=english"
      var cc = country
      return cc ? url + "&cc=" + encodeURIComponent(cc) : url
    }
    if (store === "epic") return "https://store.epicgames.com/graphql"
    if (store === "amazon") return Model.SEARCH_URLS.amazon
    return "https://www.gog.com/giveaway/api/get"
  }

  function fetchArgsMobile(platform) {
    var deadlineSeconds = Math.ceil(fetchDeadlineMs / 1000)
    return [
      "curl", "-sS", "--max-time", String(deadlineSeconds),
      "--max-filesize", String(Model.MAX_BYTES),
      "-A", Model.USER_AGENT,
      "-H", "Accept: application/json",
      "--write-out", "\n%{http_code}",
      Model.epicMobileUrl(platform, country)
    ]
  }

  // Unified completion handler for Steam, Epic PC, GOG, and Amazon fetches.
  // Called only after CommandRunner confirms both process exit and full stdout.
  function handleFetchFinished(store, exitCode, output) {
    var action = Model.httpResultAction(store, exitCode, output)
    if (!action.ok) {
      if (store === "epic") {
        failEpicPart("pc")
        return
      }
      fail(store, action.error, action.retryable)
      return
    }
    if (action.empty) {
      succeed(store, [])
      return
    }

    var parsed
    try {
      parsed = Model.parseStore(store, action.body)
    } catch (e) {
      if (store === "epic") {
        failEpicPart("pc")
        return
      }
      fail(store, "Store returned an unexpected response", true)
      return
    }
    if (!parsed.ok) {
      if (store === "epic") {
        failEpicPart("pc")
        return
      }
      fail(store, "Store returned an unexpected response", true)
      return
    }
    if (store === "epic") {
      finishEpicPart("pc", parsed.games, parsed.upcoming || [])
      return
    }
    succeed(store, parsed.games)
  }

  function handleEpicMobileFinished(platform, exitCode, output) {
    var action = Model.httpResultAction("epic", exitCode, output)
    if (!action.ok) {
      failEpicPart(platform)
      return
    }
    var parsed
    try {
      parsed = Model.parseEpicMobile(action.body, platform)
    } catch (e) {
      failEpicPart(platform)
      return
    }
    if (!parsed.ok) {
      failEpicPart(platform)
      return
    }
    finishEpicPart(platform, parsed.games)
  }

  // Send desktop notifications for a store, bundling when the batch exceeds
  // maxStoreNotifications.
  function dispatchAlerts(store, alerts, makeArgs) {
    if (!alerts || alerts.length === 0) return
    if (maxStoreNotifications >= 1 && alerts.length > maxStoreNotifications) {
      var summary = makeArgs(store, alerts)
      if (summary) Quickshell.execDetached(summary)
    } else {
      for (var a = 0; a < alerts.length; a++) {
        var argv = makeArgs(store, [alerts[a]])
        if (argv) Quickshell.execDetached(argv)
      }
    }
  }

  // `recordBaseline` is false for a partial Epic result: the missing feed must
  // keep its recorded ids, or every game it had would look new when it returns.
  function succeed(store, games, recordBaseline, upcoming) {
    var now = Date.now()
    var fields = {
      games: games,
      error: "",
      busy: false,
      neverChecked: false,
      lastSuccessAt: now,
      retryDelayMs: 30000,
      retryAt: 0
    }
    if (upcoming !== undefined) fields.upcoming = upcoming
    setBucket(store, fields)
    nowMs = now

    if (recordBaseline === false) {
      if (cursorActive) setCursorById(keepSelectedId())
      updateBusy()
      return
    }

    var transition = Model.diffStore(seenState, store, games,
      storesOn[store], notifyOn[store])
    seenState = transition.state
    persistSeen()

    var alerts = transition.alerts
    if (store === "epic" && epicHideAddOns && alerts.length > 0) {
      var addOnIds = {}
      for (var i = 0; i < games.length; i++) {
        if (games[i] && games[i].isAddOn === true) addOnIds[games[i].id] = true
      }
      var kept = []
      for (var j = 0; j < alerts.length; j++) {
        if (!addOnIds[alerts[j].id]) kept.push(alerts[j])
      }
      alerts = kept
    }
    dispatchAlerts(store, alerts, Model.notificationArgs)

    lastSuccessAt = now
    if (cursorActive) setCursorById(keepSelectedId())
    updateBusy()
    checkEndingSoonReminders()
  }

  // Schedule a per-store backoff retry with +/- 5% jitter, keeping existing
  // games visible until a later fetch succeeds.
  function scheduleRetry(store, message, retryable) {
    var b = bucket(store)
    var delay = b.retryDelayMs || 30000
    var jitter = 0.95 + Math.random() * 0.1
    var retryAt = retryable === false ? 0 : (Date.now() + Math.round(delay * jitter))
    var nextDelay = retryable === false ? delay : Math.min(60 * 60 * 1000, delay * 2)
    setBucket(store, {
      error: message,
      retryDelayMs: nextDelay,
      retryAt: retryAt
    })
  }

  // A failed fetch never overwrites the last good list: the bucket keeps its
  // games and simply gains an error, so the panel shows stale-with-error.
  function fail(store, message, retryable) {
    var b = bucket(store)
    setBucket(store, {
      games: b.games,
      busy: false,
      neverChecked: b.neverChecked
    })
    scheduleRetry(store, message, retryable)
    updateBusy()
  }

  function runDueRetries() {
    if (!seenLoaded) return
    var now = Date.now()
    for (var i = 0; i < Model.STORES.length; i++) {
      var store = Model.STORES[i]
      if (storesOn[store] !== true) continue
      var b = bucket(store)
      if (!b.busy && b.retryAt > 0 && now >= b.retryAt) {
        startFetch(store)
      }
    }
  }

  function checkEndingSoonReminders() {
    if (!seenLoaded || !endingSoonNotify) return
    var now = Date.now()
    var res = Model.endingSoonReminders(
      seenState, enabledBuckets(), storesOn, notifyOn, endingSoonNotify, now)
    if (!res.changed) return
    seenState = res.state
    persistSeen()
    for (var i = 0; i < Model.STORES.length; i++) {
      var store = Model.STORES[i]
      var alerts = res.alertsByStore[store]
      if (!alerts || alerts.length === 0) continue
      dispatchAlerts(store, alerts, function(st, list) {
        return Model.endingSoonNotificationArgs(st, list, now)
      })
    }
  }

  function keepSelectedId() {
    var current = selectedGame()
    if (!current) return ""
    return current.store + ":" + current.game.id
  }

  // Re-find the highlighted game by id after a refresh or seen toggle, falling
  // back to the nearest surviving game row when hideSeen removes it.
  function setCursorById(key, fallbackPos) {
    var allowed = gameRowIndexes()
    if (allowed.length === 0) {
      selectedIndex = -1
      return
    }
    if (key) {
      for (var a = 0; a < allowed.length; a++) {
        var row = visibleGames[allowed[a]]
        if (row.store + ":" + row.game.id === key) {
          setCursor(a)
          return
        }
      }
    }
    var target = (fallbackPos !== undefined && fallbackPos >= 0)
      ? Math.min(fallbackPos, allowed.length - 1) : 0
    setCursor(target)
  }

  function updateBusy() {
    var busy = false
    for (var i = 0; i < Model.STORES.length; i++) {
      if (bucket(Model.STORES[i]).busy) busy = true
    }
    anyBusy = busy
  }

  // The cursor walks live game rows only, skipping headers, hidden summaries,
  // and upcoming previews.
  function gameRowIndexes() {
    var out = []
    for (var i = 0; i < visibleGames.length; i++) {
      if (visibleGames[i].kind === "game") out.push(i)
    }
    return out
  }

  function setCursor(index) {
    var allowed = gameRowIndexes()
    if (allowed.length === 0) {
      selectedIndex = -1
      return
    }
    selectedIndex = allowed[Math.max(0, Math.min(allowed.length - 1, index))]
    Qt.callLater(function() { scrollCursorIntoView() })
  }

  function moveCursor(step) {
    var allowed = gameRowIndexes()
    if (allowed.length === 0) return
    var at = allowed.indexOf(selectedIndex)
    var next = at < 0 ? (step > 0 ? 0 : allowed.length - 1) : at + step
    next = Math.max(0, Math.min(allowed.length - 1, next))
    setCursor(next)
    targetStore = visibleGames[allowed[next]].store
  }

  function selectedGame() {
    if (selectedIndex < 0 || selectedIndex >= visibleGames.length) return null
    var row = visibleGames[selectedIndex]
    return row && row.kind === "game" ? row : null
  }

  function reanchorCursor() {
    if (!cursorActive) return
    var allowed = gameRowIndexes()
    if (allowed.indexOf(selectedIndex) < 0) {
      setCursor(allowed.length > 0 ? 0 : -1)
    }
  }

  function scrollCursorIntoView() {
    if (!panelList || selectedIndex < 0) return
    panelList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function launchUrlFor(store, game) {
    if (store === "steam" && steamUseClient && game) {
      var client = Model.steamClientUrl(game)
      if (client) return client
    }
    return (game && Model.safeUrl(store, game.url)) || Model.searchUrl(store)
  }

  function openGame(row) {
    if (!row || row.kind !== "game") return
    targetStore = row.store
    markSeen(row.store, row.game.id)
    var url = launchUrlFor(row.store, row.game)
    Qt.openUrlExternally(url)
    close()
  }

  function openUpcoming(row) {
    if (!row || row.kind !== "upcoming") return
    var url = (row.game && Model.safeUrl(row.store, row.game.url))
      || Model.searchUrl(row.store)
    Qt.openUrlExternally(url)
    close()
  }

  // Open a game from its store and id, for a notification action.
  function openGameById(store, id) {
    if (Model.STORES.indexOf(store) < 0) return
    var clean = Model.scrubId(id)
    if (!clean) return
    var games = bucket(store).games || []
    var game = null
    for (var i = 0; i < games.length; i++) {
      if (games[i] && games[i].id === clean) { game = games[i]; break }
    }
    markSeen(store, clean)
    var url = launchUrlFor(store, game)
    Qt.openUrlExternally(url)
    close()
  }

  function openSelected() {
    openGame(selectedGame())
  }

  // Read-only JSON export for IPC scripting (omarchy-shell ... list).
  function exportListJson() {
    var stores = {}
    for (var i = 0; i < Model.STORES.length; i++) {
      var s = Model.STORES[i]
      if (storesOn[s] !== true) continue
      var b = bucket(s)
      var games = visibleGamesFor(s)
      var items = []
      for (var j = 0; j < games.length; j++) {
        var g = games[j]
        items.push({
          id: g.id,
          title: g.title,
          url: Model.safeUrl(s, g.url) || Model.searchUrl(s),
          platform: g.platform || "",
          redeem: g.redeem || "",
          isAddOn: g.isAddOn === true,
          endsAt: g.endsAt || "",
          seen: !gameUnseen(s, g.id)
        })
      }
      var entry = {
        games: items,
        error: b.error || "",
        lastSuccessAt: b.lastSuccessAt || 0
      }
      if (s === "epic" && epicShowUpcoming) {
        var rawUp = Array.isArray(b.upcoming) ? b.upcoming : []
        var filteredUp = epicHideAddOns ? Model.filterEpicAddOns(rawUp, true) : rawUp
        var upItems = []
        for (var u = 0; u < filteredUp.length; u++) {
          var ug = filteredUp[u]
          if (!ug) continue
          upItems.push({
            id: ug.id,
            title: ug.title,
            url: Model.safeUrl("epic", ug.url) || Model.searchUrl("epic"),
            isAddOn: ug.isAddOn === true,
            startsAt: ug.startsAt || "",
            endsAt: ug.endsAt || ""
          })
        }
        entry.upcoming = upItems
      }
      stores[s] = entry
    }
    return JSON.stringify({
      updatedAt: lastSuccessAt,
      stale: stale,
      stores: stores
    })
  }

  // --- IPC ---------------------------------------------------------------

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function list(): string { return root.exportListJson() }
    function markAllSeen(): void { root.markAllSeen() }
    // Notification actions. Both take the store and game id as separate string
    // arguments; the widget validates them before touching state or a URL.
    function markSeen(store: string, id: string): void { root.markSeen(store, id) }
    function openGame(store: string, id: string): void { root.openGameById(store, id) }
  }

  // --- Processes ---------------------------------------------------------

  CommandRunner {
    id: loadSeenProc
    command: [root.python, root.seenStatePath, "load", root.stateDir]
    Component.onCompleted: start()
    onFinished: function(exitCode, output) {
      // A missing or unreadable seen.json is not primed, so the first fetch
      // records silently rather than announcing everything.
      root.ingestSeen(exitCode === 0 ? output : "")
      root.refresh()
    }
  }

  Process {
    id: saveSeenProc
    property string payload: ""
    command: [root.python, root.seenStatePath, "save", root.stateDir]
    stdinEnabled: true
    onStarted: write(payload)
    onExited: {
      if (root.seenSavePending) {
        root.seenSavePending = false
        root.persistSeen()
      }
    }
  }

  // One synchronized runner per store, so a slow store cannot hold up the
  // others and stdout is guaranteed flushed before parsing runs.
  CommandRunner {
    id: steamProc
    onFinished: function(exitCode, output) { root.handleFetchFinished("steam", exitCode, output) }
  }

  CommandRunner {
    id: epicProc
    onFinished: function(exitCode, output) { root.handleFetchFinished("epic", exitCode, output) }
  }

  CommandRunner {
    id: epicMobileAndroidProc
    onFinished: function(exitCode, output) { root.handleEpicMobileFinished("android", exitCode, output) }
  }

  CommandRunner {
    id: epicMobileIosProc
    onFinished: function(exitCode, output) { root.handleEpicMobileFinished("ios", exitCode, output) }
  }

  CommandRunner {
    id: gogProc
    onFinished: function(exitCode, output) { root.handleFetchFinished("gog", exitCode, output) }
  }

  CommandRunner {
    id: amazonProc
    onFinished: function(exitCode, output) { root.handleFetchFinished("amazon", exitCode, output) }
  }

  readonly property var fetchProcs: ({
    "steam": steamProc,
    "epic": epicProc,
    "gog": gogProc,
    "amazon": amazonProc
  })

  // --- Timers ------------------------------------------------------------

  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: persistDebounce
    // Only a safety net now: the normal flush is on panel close.
    interval: 5000
    repeat: false
    onTriggered: root.flushPersist()
  }

  Timer {
    id: retryTickTimer
    interval: 5000
    running: root.hasPendingRetries
    repeat: true
    onTriggered: root.runDueRetries()
  }

  Timer {
    id: copyFeedbackTimer
    interval: 2000
    repeat: false
    onTriggered: root.copyFeedbackText = ""
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: {
      root.nowMs = Date.now()
      root.checkEndingSoonReminders()
    }
  }

  // --- Bar mark ----------------------------------------------------------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.BAR_ICON
    dimmed: !root.hasGames || root.stale
    tooltipText: {
      var title = Model.statusTitle(root.displayBuckets(), root.storesOn, root.anyBusy)
      var detail = Model.tooltipDetail(root.displayBuckets(), root.storesOn)
      return detail ? (title + "\n" + detail + "\n" + root.freshness)
                    : (title + "\n" + root.freshness)
    }

    onPressed: function(buttonCode) {
      // Left opens the panel, middle refreshes. Right-click is deliberately
      // unused so it cannot open anything behind the user's back.
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // The unseen marker, drawn over the chest rather than beside it: a bar that
  // changes width every time something arrives is a bar that twitches all day.
  // Geometry and colour follow the notification-center widget's badge.
  Rectangle {
    id: unseenDot
    visible: root.hasUnseen
    anchors.right: button.right
    anchors.rightMargin: Style.space(3)
    anchors.top: button.top
    anchors.topMargin: Style.space(5)
    width: Style.space(6)
    height: width
    radius: width / 2
    color: Commons.Color.accent
  }

  // --- Panel -------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(pinned.height
                                             + (root.showSettings
                                                 ? settingsView.listContentHeight
                                                   + settingsView.footerImplicitHeight
                                                 : panelList.contentHeight
                                                   + panelFooter.implicitHeight),
                                             root.showSettings ? Style.space(900) : Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // A Settings field owns the keyboard while it is focused; see
      // root.noteEditor. Without this the catcher consumes j/k/h/l, Space and
      // Enter before the field sees them.
      blocked: root.activeEditor !== null

      onMoveRequested: function(dx, dy) {
        if (root.showSettings) return
        if (!root.cursorActive) {
          root.cursorActive = true
          var allowed = root.gameRowIndexes()
          var at = allowed.indexOf(root.pointerIndex)
          if (at >= 0) {
            root.setCursor(at)
            root.moveCursor(dy)
            return
          }
          if (dy > 0) root.setCursor(0)
          else if (dy < 0) root.setCursor(allowed.length - 1)
          return
        }
        if (dy !== 0) root.moveCursor(dy)
      }

      onActivateRequested: if (!root.showSettings && root.cursorActive) root.openSelected()
      onCloseRequested: {
        // Esc backs out one level at a time rather than dumping the user
        // out of the panel from deep inside Settings.
        if (root.showSettings) root.showSettings = false
        else if (root.showShortcuts) root.showShortcuts = false
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        var key = text.toLowerCase()
        if (key === ",") {
          root.showSettings = !root.showSettings
          Qt.callLater(function() { keyCatcher.forceActiveFocus() })
          return
        }
        if (root.showSettings) {
          if (key === "r") root.refresh()
          else if (key === "v") root.toggleHideSeen()
          return
        }
        if (text === "S") {
          root.markAllSeen()
          return
        }
        if (key === "r") root.refresh()
        else if (key === "s") root.toggleHighlighted()
        else if (key === "y") root.copyHighlightedUrl()
        else if (key === "v") root.toggleHideSeen()
        else if (key === "?") root.showShortcuts = !root.showShortcuts
      }

      // The hero is pinned above the rows and stays put while they scroll.
      // It used to be the ListView's header, which meant a wrapping subtitle
      // could settle taller after the panel was sized and leave the list with a
      // few pixels of permanent scroll range.
      Column {
        id: pinned
        width: parent.width
        spacing: Style.spacing.panelGap
        // Stated rather than derived. The hero is an Item with an explicit
        // height and no implicitHeight, and this Column reports zero for itself
        // while that is true, which would leave the list starting on top of it.
        // The trailing term is clearance under the rule so the first store
        // header is not flush against it; the list still starts at this
        // Column's bottom, which is what keeps the hero pinned above the rows.
        height: hero.height + pinnedRule.height + Style.spacing.panelGap
                + Style.space(8)

        // The plugin's name, and underneath it how much is free and which
        // stores that came from.
        Item {
          id: hero
          readonly property color tint: root.hasGames
            ? root.foreground
            : (root.hasStoreError() ? root.urgent : root.dim)
          width: parent.width
          height: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: Model.BAR_ICON
            color: hero.tint
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: Model.heroTitle()
              color: hero.tint
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            // Wraps rather than elides: the count sentence is a full clause.
            // Standard case now — the caps voice moved to the title and
            // store names. Contributing stores only, so the subtitle never
            // names a section the list is not showing.
            Text {
              width: parent.width
              textFormat: Text.PlainText
              visible: text !== ""
              text: Model.heroDetail(root.displayBuckets(), root.storesOn)
              color: Qt.darker(hero.tint, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 0
              wrapMode: Text.WordWrap
            }
          }
        }

        PanelSeparator {
          id: pinnedRule
          width: parent.width
          foreground: root.foreground
        }
      }

      // Only the rows scroll. The hero above stays put.
      // A ListView rather than a Column of Repeater rows. A Repeater builds its
      // items but never lays them out, so every row sat at y = 0 with the
      // enclosing Column reporting an implicit height of zero: the panel rendered
      // blank while the data underneath was correct. A ListView also gives
      // positionViewAtIndex, which is what keeps the cursor visible.
      ListView {
        id: panelList
        visible: !root.showSettings
        anchors.top: pinned.bottom
        anchors.bottom: panelFooter.top
        anchors.left: parent.left
        anchors.right: parent.right
        clip: true
        model: root.visibleGames
        boundsBehavior: Flickable.StopAtBounds
        spacing: Style.spacing.xs
        // The wheel must not move a list that already fits. Rounding and late
        // layout can leave contentHeight a hair over height, and a few pixels of
        // drift reads as the whole panel scrolling when it should not. This is
        // the same pairing the shell uses for its own panel menus.
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        ScrollBar.vertical: ScrollBar {
          policy: ScrollBar.AsNeeded
        }

        // --- One row: a store header, a game, upcoming preview, or note ---
        delegate: Item {
          id: row
          required property var modelData
          required property int index
          width: panelList.width

          readonly property bool isHeader: modelData.kind === "header"
          readonly property bool isGame: modelData.kind === "game"
          readonly property bool isUpcoming: modelData.kind === "upcoming"
          readonly property bool isHidden: modelData.kind === "hidden"
          readonly property bool isEmpty: modelData.kind === "empty"
          readonly property bool isChecking: modelData.kind === "checking"

          // Evaluated against root.nowMs here rather than in visibleGameList()
          // so the 30s tick never rebuilds the ListView model or drops scroll.
          readonly property bool unseen: isGame && !!modelData.game
            && root.gameUnseen(modelData.store, modelData.game.id)
          readonly property bool endingSoon: isGame && !!modelData.game
            && Model.endingSoon(modelData.game.endsAt, root.nowMs)
          readonly property int hiddenEndingSoon: {
            if (!isHidden || !modelData || !Array.isArray(modelData.hiddenEndsAt)) return 0
            var count = 0
            for (var i = 0; i < modelData.hiddenEndsAt.length; i++) {
              if (Model.endingSoon(modelData.hiddenEndsAt[i], root.nowMs)) count++
            }
            return count
          }
          readonly property string redeemText: isGame && modelData.game && modelData.game.redeem
            ? Model.redeemLabel(modelData.game.redeem) : ""
          readonly property bool isAddOn: (isGame || isUpcoming) && !!modelData.game
            && modelData.game.isAddOn === true
          readonly property bool hasPlatform: isGame && !!modelData.game
            && !!modelData.game.platform
          readonly property string timeText: isGame && modelData.game && modelData.game.endsAt
            ? Model.shortTimeLeft(modelData.game.endsAt, root.nowMs)
            : (isUpcoming && modelData.game && modelData.game.startsAt
              ? Model.shortStartsIn(modelData.game.startsAt, root.nowMs) : "")

          readonly property int headerRowHeight: Style.space(30)

          implicitHeight: isHeader
            ? headerRowHeight
              + (modelData && modelData.errorLabel
                ? storeError.implicitHeight + Style.space(8) : 0)
            : isHidden
              ? hiddenNote.implicitHeight + Style.spacing.sm
              : isEmpty
                ? emptyNote.implicitHeight + Style.spacing.sm
                : isChecking
                  ? checkingNote.implicitHeight + Style.spacing.sm
                  : titleRow.implicitHeight + Style.spacing.sm

          // Store header: mark, name and flanking rules.
          Item {
            anchors.fill: parent
            visible: row.isHeader

            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.NoButton
              hoverEnabled: true
              onEntered: root.targetStore = row.modelData.store
            }

            Item {
              id: headerMark
              anchors.left: parent.left
              anchors.leftMargin: Style.space(24)
              anchors.verticalCenter: parent.verticalCenter
              width: root.markSize
              height: root.markSize

              Text {
                anchors.centerIn: parent
                visible: row.isHeader && row.modelData.store !== "epic"
                textFormat: Text.PlainText
                text: Model.STORE_GLYPHS[row.modelData.store] || ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: root.markSize
              }

              Image {
                id: epicLogo
                anchors.fill: parent
                // Only the Epic header loads the asset and allocates an
                // offscreen layer; reused game rows must not trigger it.
                source: row.isHeader && row.modelData.store === "epic"
                  ? root.pluginFile("assets/epic.svg") : ""
                fillMode: Image.PreserveAspectFit
                sourceSize.width: Math.round(width * Screen.devicePixelRatio)
                sourceSize.height: Math.round(height * Screen.devicePixelRatio)
                visible: false
                layer.enabled: row.isHeader && row.modelData.store === "epic"
              }

              MultiEffect {
                anchors.fill: epicLogo
                source: epicLogo
                visible: row.isHeader && row.modelData.store === "epic"
                colorization: 1.0
                colorizationColor: root.dim
              }
            }

            Text {
              id: headerLabel
              anchors.left: headerMark.right
              anchors.leftMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: (Model.STORE_LABELS[row.modelData.store] || "").toUpperCase()
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              font.letterSpacing: 1.0
              elide: Text.ElideRight
            }

            PanelSeparator {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.sm
              anchors.right: headerMark.left
              anchors.rightMargin: Style.space(8)
              foreground: root.foreground
              height: Style.space(2)
            }
            PanelSeparator {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: headerLabel.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.sm
              foreground: root.foreground
              height: Style.space(2)
            }
          }

          // Store error message below the header.
          Text {
            id: storeError
            anchors.top: parent.top
            anchors.topMargin: row.headerRowHeight
            anchors.left: parent.left
            anchors.leftMargin: root.storeIndent
            width: parent.width - root.storeIndent - Style.spacing.sm
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            visible: text !== ""
            text: row.modelData.errorLabel || ""
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // A live game or upcoming Epic preview row.
          Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: titleRow.implicitHeight + Style.spacing.sm
            visible: row.isGame || row.isUpcoming
            radius: Style.cornerRadius
            color: row.isGame && (root.cursorActive ? root.selectedIndex === row.index
                                                    : root.pointerIndex === row.index)
              ? (root.bar ? Style.selectedFillFor(root.bar.foreground, Commons.Color.accent)
                          : "transparent")
              : "transparent"

            // Left gutter marker: unseen coin, ending-soon hourglass, or
            // muted clock glyph for upcoming Epic rows.
            Text {
              id: gameMark
              width: root.markSize
              horizontalAlignment: Text.AlignHCenter
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              visible: row.unseen || row.endingSoon || row.isUpcoming
              textFormat: Text.PlainText
              text: row.isUpcoming
                ? "\u{F017}"
                : (row.endingSoon ? Model.HOURGLASS_GLYPH : Model.NEW_GAME_GLYPH)
              color: row.isUpcoming
                ? root.dim
                : (row.endingSoon ? root.urgent : Commons.Color.accent)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall

              PanelToolTip {
                visible: gameMouse.containsMouse && gameMouse.overGlyph
                text: row.isUpcoming
                  ? Model.startsInLabel(row.modelData.game && row.modelData.game.startsAt, root.nowMs)
                  : (row.endingSoon
                    ? (Model.endsInLabel(row.modelData.game && row.modelData.game.endsAt, root.nowMs)
                        + (row.unseen ? ". Mark as seen" : ""))
                    : "Mark as seen")
                fontFamily: root.fontFamily
              }
            }

            // Right-aligned subtle countdown ("3d", "6h", "Ended", or "in 3d").
            Text {
              id: timeLabel
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              visible: row.timeText !== ""
              textFormat: Text.PlainText
              text: row.timeText
              color: row.endingSoon ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // Title plus optional inline badges (DLC, Amazon redemption
            // storefront, or Epic mobile platform glyph).
            Row {
              id: titleRow
              anchors.left: parent.left
              anchors.right: timeLabel.visible ? timeLabel.left : parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: root.storeIndent
              anchors.rightMargin: timeLabel.visible ? Style.space(8) : Style.spacing.sm
              spacing: Style.space(4)

              readonly property real badgeWidth:
                (dlcBadge.visible ? dlcBadge.implicitWidth + spacing : 0)
                + (redeemBadge.visible ? redeemBadge.implicitWidth + spacing : 0)
                + (platformGroup.visible
                    ? separatorDot.implicitWidth + platformGroup.implicitWidth * 1.4
                      + spacing * 2 : 0)

              Text {
                id: gameTitle
                width: Math.max(0, Math.min(implicitWidth, parent.width - titleRow.badgeWidth))
                textFormat: Text.PlainText
                text: (row.isGame || row.isUpcoming) && row.modelData.game
                  ? row.modelData.game.title : ""
                // Unseen live games stand out; seen and upcoming rows stay muted.
                color: row.unseen ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Text {
                id: dlcBadge
                anchors.verticalCenter: parent.verticalCenter
                visible: row.isAddOn
                textFormat: Text.PlainText
                text: "\u00B7 DLC"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: redeemBadge
                anchors.verticalCenter: parent.verticalCenter
                visible: row.redeemText !== ""
                textFormat: Text.PlainText
                text: row.redeemText !== "" ? ("\u00B7 " + row.redeemText) : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: separatorDot
                anchors.verticalCenter: parent.verticalCenter
                visible: row.hasPlatform
                textFormat: Text.PlainText
                text: "\u00B7"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }

              Text {
                id: platformGroup
                anchors.verticalCenter: parent.verticalCenter
                visible: row.hasPlatform
                textFormat: Text.PlainText
                text: row.hasPlatform
                  ? Model.platformGlyph(row.modelData.game.platform) : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                scale: 1.4
                transformOrigin: Item.Center
              }
            }

            MouseArea {
              id: gameMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              readonly property bool overGlyph: gameMark.visible
                && mouseX >= gameMark.x && mouseX <= gameMark.x + gameMark.width
              onEntered: {
                if (!row.isGame || Date.now() < root.hoverSuppressUntil) return
                root.pointerIndex = row.index
                root.targetStore = row.modelData.store
              }
              onPositionChanged: function(mouse) {
                if (!row.isGame || Date.now() < root.hoverSuppressUntil) return
                if (!root.pointerMoved(mapToItem(null, mouse.x, mouse.y))) return
                root.pointerIndex = row.index
                root.cursorActive = false
                root.targetStore = row.modelData.store
              }
              onExited: if (root.pointerIndex === row.index) root.pointerIndex = -1
              onClicked: {
                if (row.isUpcoming) {
                  root.openUpcoming(row.modelData)
                  return
                }
                if (overGlyph && row.unseen)
                  root.markSeen(row.modelData.store, row.modelData.game.id)
                else root.openGame(row.modelData)
              }
            }
          }

          // Summary row when seen games are hidden.
          Text {
            id: hiddenNote
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: root.storeIndent
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            visible: row.isHidden
            text: row.isHidden && row.modelData
              ? Model.hiddenSeenLabel(row.modelData.count, row.hiddenEndingSoon) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleHideSeen()
            }
          }

          Text {
            id: checkingNote
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: root.storeIndent
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            visible: row.isChecking
            text: "Checking…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            id: emptyNote
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)
            visible: row.isEmpty

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "\u{F119}"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "No free game giveaways found."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
          }
        }
      }

      // Extracted in-panel Settings view.
      SettingsPage {
        id: settingsView
        visible: root.showSettings
        anchors.top: pinned.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        widget: root
        footerButtonHeight: refreshButton.implicitHeight
      }

      // Scroll edge hints for the main store list.
      Rectangle {
        id: topFade
        anchors.top: panelList.top
        anchors.left: panelList.left
        anchors.right: panelList.right
        height: Style.space(30)
        visible: !root.showSettings && panelList.interactive && !panelList.atYBeginning
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
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Rectangle {
        id: bottomFade
        anchors.bottom: panelList.bottom
        anchors.left: panelList.left
        anchors.right: panelList.right
        height: Style.space(30)
        visible: !root.showSettings && panelList.interactive && !panelList.atYEnd
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
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // --- Pinned footer -----------------------------------------------
      Column {
        id: panelFooter
        visible: !root.showSettings
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: Style.space(6)
        topPadding: Style.space(8)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          visible: root.activeStores.length === 0
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
          text: "Every store is disabled. Enable one or more stores in Settings to start watching for free game loot drops."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.showSettings = true
          }
        }

        PanelSeparator {
          id: footerRule
          width: parent.width
          foreground: root.foreground
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          visible: root.showShortcuts
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
          text: "r refresh · s seen · S all seen · y copy url · v hide seen · , settings · j/k move · enter open"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Item {
          id: footerControls
          width: parent.width
          readonly property real leftSpan: refreshButton.implicitWidth
            + Style.spacing.xs + seenButton.implicitWidth
            + (markAllButton.visible ? Style.spacing.xs + markAllButton.width : 0)
          readonly property real rightSpan: gearButton.width
            + Style.spacing.xs + helpButton.width
          implicitHeight: Math.max(centerColumn.implicitHeight,
                                   refreshButton.implicitHeight,
                                   seenButton.implicitHeight,
                                   gearButton.implicitHeight,
                                   helpButton.implicitHeight)

          Column {
            id: centerColumn
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, parent.width
              - 2 * Math.max(footerControls.leftSpan, footerControls.rightSpan)
              - Style.space(12))
            spacing: Style.space(2)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              visible: root.disabledSummary !== ""
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
              text: root.disabledSummary
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.showSettings = true
              }
            }

            Text {
              id: bottomText
              width: parent.width
              textFormat: Text.PlainText
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: root.copyFeedbackText !== "" ? root.copyFeedbackText : root.freshness
              color: root.copyFeedbackText !== ""
                ? Commons.Color.accent
                : (root.stale ? root.dim : root.footerInk)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Button {
            id: refreshButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "\u{F021}"
            bordered: true
            foreground: root.footerInk
            accent: Commons.Color.accent
            fontFamily: root.fontFamily
            tooltipText: "Refresh now"
            onClicked: root.refresh()
          }

          Button {
            id: seenButton
            anchors.left: refreshButton.right
            anchors.leftMargin: Style.spacing.xs
            anchors.verticalCenter: parent.verticalCenter
            width: refreshButton.implicitWidth
            height: refreshButton.implicitHeight
            text: root.hideSeen ? "\u{F070}" : "\u{F06E}"
            bordered: true
            foreground: root.hideSeen ? root.footerInk
                                      : Qt.darker(root.footerInk, 1.35)
            accent: Commons.Color.accent
            fontFamily: root.fontFamily
            tooltipText: root.hideSeen ? "Show seen games" : "Hide seen games"
            onClicked: root.toggleHideSeen()
          }

          // Mark all visible games as seen; appears only when unseen games exist.
          Button {
            id: markAllButton
            visible: root.hasUnseen
            anchors.left: seenButton.right
            anchors.leftMargin: Style.spacing.xs
            anchors.verticalCenter: parent.verticalCenter
            width: refreshButton.implicitWidth
            height: refreshButton.implicitHeight
            text: "\u{F00C}"
            bordered: true
            foreground: root.footerInk
            accent: Commons.Color.accent
            fontFamily: root.fontFamily
            tooltipText: "Mark all as seen (Shift+S)"
            onClicked: root.markAllSeen()
          }

          Button {
            id: gearButton
            anchors.right: helpButton.left
            anchors.rightMargin: Style.spacing.xs
            anchors.verticalCenter: parent.verticalCenter
            width: refreshButton.implicitWidth
            height: refreshButton.implicitHeight
            text: "\u{F013}"
            bordered: true
            foreground: root.footerInk
            accent: Commons.Color.accent
            fontFamily: root.fontFamily
            tooltipText: "Settings"
            onClicked: {
              root.showSettings = !root.showSettings
              Qt.callLater(function() { keyCatcher.forceActiveFocus() })
            }
          }

          Button {
            id: helpButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: refreshButton.implicitWidth
            height: refreshButton.implicitHeight
            text: "?"
            bordered: true
            foreground: root.footerInk
            accent: Commons.Color.accent
            fontFamily: root.fontFamily
            tooltipText: "Shortcuts"
            onClicked: root.showShortcuts = !root.showShortcuts
          }
        }
      }
    }
  }

  onOpenedChanged: {
    if (!opened) {
      flushPersist()
    } else {
      cursorActive = false
      pointerIndex = -1
      targetStore = ""
      showShortcuts = false
      showSettings = false
      nowMs = Date.now()
      // Opening the panel refreshes when the data is missing or stale, which is
      // what makes a long refresh interval safe to live with.
      if (lastSuccessAt === 0 || stale) refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  SequentialAnimation {
    running: root.anyBusy
    loops: Animation.Infinite
    alwaysRunToEnd: true
    NumberAnimation {
      target: button
      property: "scale"
      to: 0.72
      duration: 260
      easing.type: Easing.InOutSine
    }
    NumberAnimation {
      target: button
      property: "scale"
      to: 1.08
      duration: 260
      easing.type: Easing.InOutSine
    }
    onStopped: button.scale = 1
  }
}
