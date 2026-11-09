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

  // Local overrides so footer toggles answer on the click itself. Going
  // through persist() alone leaves the UI waiting for the shell to echo the
  // written shell.json back, which reads as a ~1s lag on the eye and mobile
  // buttons. The override is what the panel reads; persist() still writes
  // the value for the next start, and onSettingsChanged clears the override
  // once the echo lands (it carries the same value, so nothing flickers).
  // Store watches and bells get the same treatment so enabling a store
  // flips its switch (and its section) on the click, not a second later.
  property bool hideSeenOverride: false
  property bool hideSeenOverrideValue: false
  property var epicMobileOverride: ({})
  property var storesOverride: ({})
  property var notifyOverride: ({})

  readonly property var storesOn: {
    var base = Model.enabled({
      "steamEnabled": setting("steamEnabled", true),
      "epicEnabled": setting("epicEnabled", true),
      "gogEnabled": setting("gogEnabled", true),
      "amazonEnabled": setting("amazonEnabled", false)
    })
    for (var s in storesOverride) base[s] = storesOverride[s]
    return base
  }
  readonly property var notifyOn: {
    var base = Model.notifyFor({
      "steamNotify": setting("steamNotify", true),
      "epicNotify": setting("epicNotify", true),
      "gogNotify": setting("gogNotify", true),
      "amazonNotify": setting("amazonNotify", true)
    })
    for (var n in notifyOverride) base[n] = notifyOverride[n]
    return base
  }

  readonly property var epicMobileOn: ({
    "android": epicMobileOverride.android !== undefined
      ? epicMobileOverride.android
      : setting("epicMobileAndroid", false),
    "ios": epicMobileOverride.ios !== undefined
      ? epicMobileOverride.ios
      : setting("epicMobileIos", false)
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
  readonly property bool hideSeen: hideSeenOverride
    ? hideSeenOverrideValue
    : setting("hideSeen", false)

  // Per-store results. Each bucket keeps its own games, error and timestamp so
  // one store failing never blanks the others.
  property var buckets: ({
    "steam": newBucket(),
    "epic": newBucket(),
    "gog": newBucket(),
    "amazon": newBucket()
  })

  property var seenState: Model.emptySeen()
  property bool seenLoaded: false
  property bool anyBusy: false
  // Epic assembly buffer: the PC catalog and the Android/iOS discover feeds
  // are fetched by separate processes so one slow or failing feed cannot
  // delay or blank the others. Parts are stashed here and only merged by
  // finalizeEpic() once every expected part has answered.
  property var epicParts: null
  property double lastSuccessAt: 0
  property double nowMs: Date.now()
  property int retryDelayMs: 30000
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
  // Which store the pointer or cursor last touched. Kept for future use;
  // there is no longer a per-store keybind acting on it.
  property string targetStore: ""
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
  // store list. The gear in the footer toggles it; it hosts every setting
  // that used to be config-only (refresh interval, notification limit,
  // store country) plus the Epic mobile platform switches.
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
  // The footer's ink, shared by the freshness text and both buttons so the two
  // cannot drift apart. The text drops to `dim` once the data is stale; the
  // buttons deliberately hold this colour, so they stay equally usable when the
  // numbers behind them are old.
  readonly property color footerInk: Qt.darker(foreground, 1.5)
  readonly property string freshness: Model.freshnessLabel(
    lastSuccessAt, nowMs, anyBusy, staleAfter)
  readonly property var activeStores: Model.activeStores(storesOn)
  readonly property var visibleGames: visibleGameList()
  // How many rows the panel's Repeater actually instantiated. This is not the
  // same as visibleGames.length: a Repeater bound to a property that does not
  // exist renders nothing while the array behind it stays perfectly correct, so
  // the harness asserts on this instead.
  readonly property int renderedRows: panelList.count

  // Rows must be laid out, not merely built. The previous Column-of-Repeater
  // rendered a blank panel while reporting a correct row count and a model of
  // seven, because a Repeater builds delegates but positions none of them. The
  // measure that actually distinguishes the two is the view's contentHeight:
  // it is zero when every row has no height, and it grows with each positioned
  // row.
  //
  // A function rather than a binding, because reading an item's geometry
  // creates no dependency and a property bound to it goes stale after one read.
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
    return { games: [], error: "", busy: false, neverChecked: true, lastSuccessAt: 0 }
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
  // Both arrive as position changes, so the scene point is what tells them
  // apart: scrolling changes the row's position, not the pointer's.
  function pointerMoved(scenePoint) {
    var threshold = Style.space(4)
    var moved = lastPointerScene.x < 0
      || Math.abs(scenePoint.x - lastPointerScene.x) >= threshold
      || Math.abs(scenePoint.y - lastPointerScene.y) >= threshold
    lastPointerScene = scenePoint
    return moved
  }

  // Flat, store-ordered list for the single cursor. Reordered on every change
  // so the highlighted row stays on the same game when a refresh lands.
  // Flat list of row entries: a header ahead of every store, then that store's
  // games when it is being watched. Headers share the index space with games so
  // The cursor is a plain index and a row can be fetched by position to scroll
  // it into view.
  //
  // A switched-off store is never listed; see the disabled line at the end.
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
      // A store only gets a section when it is watched and has something
      // to show: game rows, or a hidden-seen count in hide-seen mode. A
      // switched-off store never appears, however many games it last had.
      var hasEntries = on && (shown.length > 0 || hidden > 0 || current.busy)
      var failed = on && !!current.error
      if (!hasEntries && !failed) continue
      list.push({
        kind: "header",
        store: store,
        errorLabel: Model.storeErrorLabel(store, errorsByStore())
      })
      // A store with nothing yet but a fetch in flight says so, instead
      // of sitting empty while the network catches up.
      if (shown.length === 0 && hidden === 0 && current.busy) {
        list.push({ kind: "checking", store: store })
      }
      for (var j = 0; j < shown.length; j++) {
        list.push({ kind: "game", store: store, game: shown[j] })
      }
      // The summary is the store's last entry, so every unseen game reads first.
      if (hidden > 0) {
        var soon = 0
        for (var s = 0; s < seenGames.length; s++) {
          if (Model.endingSoon(seenGames[s] && seenGames[s].endsAt, nowMs)) soon++
        }
        list.push({ kind: "hidden", store: store, count: hidden, endingSoon: soon })
      }
    }
    if (anyEnabled && list.length === 0 && !anyBusy) list.push({ kind: "empty" })
    return list
  }

  // Write a setting change back to this widget's entry in shell.json. Applied
  // locally first so the switch moves on the click itself, then persisted; the
  // bar feeds the same value back through settings a moment later. This is the
  // same pattern Omarchy's own Tray and Clock widgets use. The shell write is
  // deferred to the next event loop turn so the click paints before the
  // file I/O (and any bar reload it triggers) can stall it.
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
    // Shell writes are flushed when the panel closes, not per toggle:
    // updateEntryInline makes the shell reload its config and rebuild
    // the bar, which stalls the panel ~1s on the first toggle of a
    // session. Local state answers instantly either way.
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

  // One-time copy of the pre-Epic country key. Fires on either injection order:
  // `bar` supplies the write path, `settings` the values, and the patch check
  // makes a second call harmless.
  onBarChanged: migrateCountry()
  onSettingsChanged: {
    // The shell echo after a footer toggle carries the same value the local
    // override already shows, so dropping the override changes nothing
    // visually while letting future external edits through.
    hideSeenOverride = false
    epicMobileOverride = ({})
    storesOverride = ({})
    notifyOverride = ({})
    migrateCountry()
  }

  function migrateCountry() {
    var patch = Model.countryPatch(root.settings)
    if (!patch) return
    if (!root.bar || !root.bar.shell
        || typeof root.bar.shell.updateEntryInline !== "function") return
    persist(patch)
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
      if (!platformHidden(games[i] && games[i].platform)) out.push(games[i])
    }
    return out
  }

  // The settings page as a flat row model: a heading then switch rows per
  // store, then a general section. Grouped by store because that is how
  // the watch/notify preferences are thought about.
  function settingsRows() {
    var rows = []
    for (var i = 0; i < Model.STORES.length; i++) {
      var store = Model.STORES[i]
      rows.push({ kind: "heading", label: Model.STORE_LABELS[store] || store, store: store })
      rows.push({ kind: "store", label: "", store: store })
      if (store === "epic") {
        rows.push({ kind: "platforms", label: "", store: store })
      }
    }
    rows.push({ kind: "heading", label: "General" })
    rows.push({ kind: "toggle", label: "Hide seen games",
                setting: "hideSeen", store: "", what: "hideSeen" })
    rows.push({ kind: "sliderRefresh", label: "Refresh interval" })
    rows.push({ kind: "sliderNotify", label: "Store notification limit" })
    rows.push({ kind: "country", label: "Store country" })
    return rows
  }

  // Only the lone "Hide seen games" toggle routes through these; every store
  // and platform switch binds its state directly.
  function settingsToggleChecked(entry) {
    return !!entry && entry.what === "hideSeen" && hideSeen
  }

  function settingsToggleFlip(entry) {
    if (entry && entry.what === "hideSeen") toggleHideSeen()
  }

  // Buckets as the panel actually reads them: only watched stores, and
  // only their visible games. The hero count, tooltip, bar dot and store
  // error all read this, so a switched-off store cannot inflate any of
  // them.
  function displayBuckets() {
    return enabledBuckets()
  }

  // Switching a store off stops it being fetched at all; switching it back on
  // re-records silently rather than announcing everything it missed.
  function toggleStore(store) {
    targetStore = store
    suppressHover()
    var turningOn = storesOn[store] !== true
    var next = {}
    for (var s in storesOn) next[s] = storesOn[s]
    next[store] = turningOn
    storesOverride = next
    persist({ [enabledKey(store)]: turningOn })
    // Re-enabling re-records silently: the baseline and the seen marks stay,
    // but priming is dropped so nothing from the off period is announced.
    if (turningOn && seenLoaded) {
      seenState = Model.unprimeStore(seenState, store)
      persistSeen()
    }
    reanchorCursor()
    // Fetch just this store now (stale rows if it has them are already
    // visible), instead of the slowest store on a full refresh.
    if (turningOn && !bucket(store).busy) startFetch(store)
  }

  function toggleBell(store) {
    targetStore = store
    var next = {}
    for (var n in notifyOn) next[n] = notifyOn[n]
    next[store] = notifyOn[store] !== true
    notifyOverride = next
    persist({ [notifyKey(store)]: next[store] })
  }

  function suppressHover() {
    hoverSuppressUntil = Date.now() + 1000
    cursorActive = false
    pointerIndex = -1
    selectedIndex = -1
    lastPointerScene = Qt.point(-1, -1)
  }

  // A toggle that reshapes the list clears any selection outright instead
  // of re-anchoring it: clamp-and-rehighlight picks whichever row now
  // happens to sit at the old index and flashes it for a frame.
  function resetSelectionAfterToggle() {
    suppressHover()
  }

  // Epic mobile sub-platform switches, toggled from the panel footer. The
  // settings keys are epicMobileAndroid / epicMobileIos; map a platform to
  // the one it owns so a click never writes the other platform's key.
  function epicMobileKey(platform) {
    return platform === "ios" ? "epicMobileIos" : "epicMobileAndroid"
  }

  function toggleEpicMobile(platform) {
    if (Model.PLATFORMS.indexOf(platform) < 0) return
    var turningOn = epicMobileOn[platform] !== true
    snapPanelHeight()
    suppressHover()
    var next = { "android": epicMobileOn.android === true,
                 "ios": epicMobileOn.ios === true }
    next[platform] = turningOn
    epicMobileOverride = next
    persist({ [epicMobileKey(platform)]: turningOn })
    // Epic's mobile feeds share the epic baseline, so enabling one has to
    // re-prime that store as well; otherwise its currently free games would
    // arrive as a burst of "new" notifications.
    if (turningOn && seenLoaded) {
      seenState = Model.unprimeStore(seenState, "epic")
      persistSeen()
    }
    resetSelectionAfterToggle()
    // Enabling a platform fetches it immediately rather than waiting for
    // the next scheduled refresh, so the rows appear without a manual r.
    if (turningOn && storesOn.epic === true && !bucket("epic").busy) startFetch("epic")
  }

  // The eye hides games the user has already marked seen. Persisted like the
  // switches and bells so it survives a restart.
  function toggleHideSeen() {
    snapPanelHeight()
    var next = !hideSeen
    hideSeenOverrideValue = next
    hideSeenOverride = true
    persist({ hideSeen: next })
    resetSelectionAfterToggle()
  }

  // KeyboardPanel animates drawnHeight whenever it changes while live
  // (200ms), even for a deliberate show/hide toggle that should be instant.
  // Snapping it off here makes the next size change land in one step; the
  // panel re-arms the animation on its next open.
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

  // Whether any store currently carries an error, so the hero can turn urgent
  // without naming each store in the binding.
  function hasStoreError() {
    for (var i = 0; i < Model.STORES.length; i++) {
      var store = Model.STORES[i]
      if (storesOn[store] === true && bucket(store).error) return true
    }
    return false
  }

  // Acknowledge one game, clearing its marker and letting the bar dot go out
  // once every new game has been marked.
  function markSeen(store, id) {
    if (!seenLoaded) return
    var key = store + ":" + id
    seenState = Model.acknowledgeGame(seenState, store, id)
    persistSeen()
    // The reorder (unseen first) moves the marked row to the bottom of
    // its store, so follow it by id rather than leaving the cursor on
    // whichever game now sits at the old index.
    setCursorById(key)
  }

  // The game the highlight is on, keyboard or pointer, so h marks whichever row
  // is showing as selected.
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
    seenState = gameUnseen(store, id)
      ? Model.acknowledgeGame(seenState, store, id)
      : Model.forgetGame(seenState, store, id)
    persistSeen()
    // Follow the toggled game by id: the unseen-first reorder moves it
    // across the store block, and pressing s again must hit the same game.
    setCursorById(key)
  }

  function toggleHighlighted() {
    var row = highlightedGame()
    if (row) toggleSeen(row.store, row.game.id)
  }

  function ingestSeen(raw) {
    if (seenLoaded) return
    seenState = Model.parseSeen(raw)
    seenLoaded = true
  }

  function persistSeen() {
    if (!seenLoaded || saveSeenProc.running) return
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
        setBucket(store, { busy: false })
        continue
      }
      if (bucket(store).busy) continue
      startFetch(store)
    }
    updateBusy()
  }

  function startFetch(store) {
    setBucket(store, { busy: true })
    if (store === "epic") {
      beginEpicAssembly()
      return
    }
    var proc = fetchProcs[store]
    proc.command = [root.python, root.cappedRun, String(Model.MAX_BYTES)]
      .concat(fetchArgs(store))
    proc.running = true
    updateBusy()
  }

  // Start the PC catalog fetch plus whichever mobile platform feeds are
  // switched on. finalizeEpic() runs only after every expected part answers,
  // so a partial result is never shown as the whole Epic list.
  function beginEpicAssembly() {
    var parts = { pc: null, android: null, ios: null, failed: 0, expected: 0 }
    epicParts = parts
    var wanted = ["pc"]
    if (epicMobileOn.android === true) wanted.push("android")
    if (epicMobileOn.ios === true) wanted.push("ios")
    parts.expected = wanted.length
    for (var i = 0; i < wanted.length; i++) {
      var which = wanted[i]
      if (which === "pc") {
        epicProc.command = [root.python, root.cappedRun, String(Model.MAX_BYTES)]
          .concat(fetchArgs("epic"))
        epicProc.running = true
      } else if (which === "android") {
        epicMobileAndroidProc.command = [root.python, root.cappedRun, String(Model.MAX_BYTES)]
          .concat(fetchArgsMobile("android"))
        epicMobileAndroidProc.running = true
      } else {
        epicMobileIosProc.command = [root.python, root.cappedRun, String(Model.MAX_BYTES)]
          .concat(fetchArgsMobile("ios"))
        epicMobileIosProc.running = true
      }
    }
    updateBusy()
  }

  function finishEpicPart(which, games) {
    // A part answers through both its stream and its exit, so only the first
    // to arrive is recorded; the second is a no-op. Otherwise a failing feed
    // counts its failure twice (once per handler) and flips a partial failure
    // into a total one.
    if (!epicParts || epicParts[which] !== null) return
    epicParts[which] = games || []
    checkEpicAssembly()
  }

  function failEpicPart(which) {
    if (!epicParts || epicParts[which] !== null) return
    epicParts[which] = []
    epicParts.failed++
    checkEpicAssembly()
  }

  function checkEpicAssembly() {
    if (!epicParts) return
    var result = Model.epicAssemblyResult(epicParts)
    if (!result) return
    epicParts = null
    // A feed that failed does not fail the store while another part still
    // answered: the user sees what we have and the error line names what is
    // missing. Only a total failure is an unreachable store.
    if (result.mode === "partial") {
      succeed("epic", result.games)
      setBucket("epic", { error: "Could not reach Epic Mobile" })
    } else if (result.mode === "fail") {
      fail("epic", "Could not reach Epic")
    } else {
      succeed("epic", result.games)
    }
  }

  // Bridge between the generic publish() and the assembly buffer: the PC
  // catalog answers through publish(), mobile through publishEpicMobile().
  // publish() is called with "epic" for PC; see publishEpicMobile.

  function fetchArgs(store) {
    // Amazon is rendered rather than requested, so a browser is its transport.
    if (store === "amazon") return amazonArgs()
    var deadlineSeconds = Math.ceil(fetchDeadlineMs / 1000)
    var args = [
      "curl", "-fsS", "--max-time", String(deadlineSeconds),
      // --max-filesize is only honoured against a declared Content-Length, so
      // capped-run is what actually bounds a response that streams.
      "--max-filesize", String(Model.MAX_BYTES),
      "-A", Model.USER_AGENT,
      "-H", "Accept: application/json,text/html;q=0.9",
      // Steam's search endpoint only answers with JSON for an XHR.
      "-H", "X-Requested-With: XMLHttpRequest",
      // The status code is appended so GOG's 404 can be told apart from a
      // network failure; curl -f alone would make both a non-zero exit.
      "--write-out", "\n%{http_code}"
    ]
    // Epic is the only store queried with a POST. The GraphQL body is one argv
    // element handed straight to curl, so no shell quoting is involved.
    if (store === "epic") {
      args.push("-H", "Content-Type: application/json",
        "--data", Model.epicQuery(country))
    }
    args.push(sourceUrl(store))
    return args
  }

  // Luna's claims grid exists only after its scripts run, and the GraphQL
  // behind it rejects clients that do not look like a browser, so this store is
  // fetched by rendering the signed-out page in Chromium — a base Omarchy
  // package. Both the browser and `timeout`, which supplies the deadline curl
  // gives itself, are named absolutely so PATH cannot shadow them; capped-run
  // still bounds the DOM printed to stdout.
  // shortcut: no sign-in-wall detection; a wall requires a session this store
  // does not have, and it surfaces as the generic unexpected-response error.
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
      // maxprice=free&specials=1 lists 100%-off specials, so free-to-play
      // titles are excluded without a second filter.
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
      "curl", "-fsS", "--max-time", String(deadlineSeconds),
      "--max-filesize", String(Model.MAX_BYTES),
      "-A", Model.USER_AGENT,
      "-H", "Accept: application/json",
      "--write-out", "\n%{http_code}",
      Model.epicMobileUrl(platform, country)
    ]
  }

  // curl's -f makes a 404 an error exit, but GOG's 404 means "no giveaway
  // running" rather than a failure. The body is empty in that case, so the
  // store is reported healthy and empty.
  function publish(store, raw) {
    var body = String(raw || "")
    var code = "200"
    // curl appends its status code; the Amazon render is raw DOM, whose last
    // line is markup rather than a status.
    if (store !== "amazon") {
      var split = body.lastIndexOf("\n")
      if (split >= 0) {
        code = body.slice(split + 1).trim()
        body = body.slice(0, split)
      }
    }

    if (code === "404" && store === "gog") {
      succeed(store, [])
      return
    }

    // A parser that throws must not leave the store busy forever. refresh()
    // skips a store whose bucket is busy, so an exception escaping this callback
    // would strand that store with no error shown and no way to retry. Turn any
    // throw into the same store error a bad response gets.
    var parsed
    try {
      parsed = Model.parseStore(store, body)
    } catch (e) {
      fail(store, "Store returned an unexpected response")
      return
    }
    if (!parsed.ok) {
      if (store === "epic") {
        failEpicPart("pc")
        return
      }
      fail(store, "Store returned an unexpected response")
      return
    }
    if (store === "epic") {
      finishEpicPart("pc", parsed.games)
      return
    }
    succeed(store, parsed.games)
  }

  // Mobile discover feeds answer into the Epic assembly, not straight to the
  // bucket, so the PC snapshot and both platforms merge in one succeed().
  function publishEpicMobile(platform, raw) {
    var body = String(raw || "")
    var split = body.lastIndexOf("\n")
    if (split >= 0) body = body.slice(0, split)
    var parsed
    try {
      parsed = Model.parseEpicMobile(body, platform)
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

  function succeed(store, games) {
    var now = Date.now()
    setBucket(store, {
      games: games,
      error: "",
      busy: false,
      neverChecked: false,
      lastSuccessAt: now
    })

    var transition = Model.diffStore(seenState, store, games,
      storesOn[store], notifyOn[store])
    seenState = transition.state
    persistSeen()

    // Bundle a store's new games into one summary once they pass the per-store
    // cap, so a sudden batch does not become a wall of cards. A cap of 0 means
    // no limit; below the cap each game gets its own notification with its own
    // store-page and mark-seen buttons.
    if (maxStoreNotifications >= 1
        && transition.alerts.length > maxStoreNotifications) {
      var summary = Model.notificationArgs(store, transition.alerts)
      if (summary) Quickshell.execDetached(summary)
    } else {
      for (var a = 0; a < transition.alerts.length; a++) {
        var argv = Model.notificationArgs(store, [transition.alerts[a]])
        if (argv) Quickshell.execDetached(argv)
      }
    }

    nowMs = now
    lastSuccessAt = now
    retryTimer.stop()
    retryDelayMs = 30000
    setCursorById(keepSelectedId())
    updateBusy()
  }

  // A failed fetch never overwrites the last good list: the bucket keeps its
  // games and simply gains an error, so the panel shows stale-with-error.
  function fail(store, message) {
    var bucketNow = bucket(store)
    setBucket(store, {
      games: bucketNow.games,
      error: message,
      busy: false,
      neverChecked: bucketNow.neverChecked
    })
    retryTimer.interval = retryDelayMs
    retryTimer.restart()
    retryDelayMs = Math.min(60 * 60 * 1000, retryDelayMs * 2)
    updateBusy()
  }

  function keepSelectedId() {
    var current = selectedGame()
    if (!current) return ""
    return current.store + ":" + current.game.id
  }

  // Re-find the highlighted game by id after a refresh, so an incoming list
  // does not move the cursor onto a different row.
  function setCursorById(key) {
    if (!key) {
      setCursor(0)
      return
    }
    var allowed = gameRowIndexes()
    for (var a = 0; a < allowed.length; a++) {
      var row = visibleGames[allowed[a]]
      if (row.store + ":" + row.game.id === key) {
        setCursor(a)
        return
      }
    }
    setCursor(0)
  }

  function updateBusy() {
    var busy = false
    for (var i = 0; i < Model.STORES.length; i++) {
      if (bucket(Model.STORES[i]).busy) busy = true
    }
    anyBusy = busy
  }

  // The cursor walks game rows only, skipping headers and the hidden summary,
  // and never leaves the viewport: the selected row is fetched from the
  // Repeater and scrolled to.
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

  // Move by a step in games, not rows, so a header between two stores does not
  // consume a keypress. The cursor position is a row index while the step is an
  // offset in games, so the two are converted rather than mixed: doing that
  // loosely left the cursor on whichever store happened to slide into the freed
  // slot, which is why e and n appeared to only ever act on one store.
  function moveCursor(step) {
    var allowed = gameRowIndexes()
    if (allowed.length === 0) return
    var at = allowed.indexOf(selectedIndex)
    var next = at < 0 ? (step > 0 ? 0 : allowed.length - 1) : at + step
    next = Math.max(0, Math.min(allowed.length - 1, next))
    setCursor(next)
    // Moving the cursor retargets the keyboard. Re-anchoring must not, or
    // switching a store off would immediately retarget it elsewhere.
    targetStore = visibleGames[allowed[next]].store
  }

  function selectedGame() {
    if (selectedIndex < 0 || selectedIndex >= visibleGames.length) return null
    var row = visibleGames[selectedIndex]
    return row && row.kind === "game" ? row : null
  }

  // Re-anchor the cursor after the row list changes underneath it.
  function reanchorCursor() {
    var allowed = gameRowIndexes()
    if (allowed.indexOf(selectedIndex) < 0) {
      setCursor(allowed.length > 0 ? 0 : -1)
    }
  }

  // Keep the highlighted row inside the visible area. ListView does the
  // measuring, which is why the panel is a ListView and not a Column of
  // Repeater rows.
  function scrollCursorIntoView() {
    if (!panelList || selectedIndex < 0) return
    panelList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function openGame(row) {
    if (!row || row.kind !== "game") return
    targetStore = row.store
    // Launching is one of the ways a game is acknowledged. The panel is about
    // to close, so the marker would not be seen to clear, but the bar dot and
    // the next open reflect it.
    markSeen(row.store, row.game.id)
    // safeUrl refuses anything off the store's own host, and the search page is
    // the fallback, so a row always opens somewhere legitimate.
    var url = Model.safeUrl(row.store, row.game.url) || Model.searchUrl(row.store)
    // Handed to xdg-open rather than launched directly: the browser then picks
    // its own last-used window, instead of being second-guessed by
    // omarchy-launch-browser's focus step.
    Qt.openUrlExternally(url)
    close()
  }

  // Open a game from its store and id, for a notification action. The store and
  // id arrive over IPC, so treat them as untrusted: an unknown store or a
  // missing/invalid id does nothing, and the URL is re-derived from the
  // allowlisted game record (or the store listing), never passed in.
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
    var url = game
      ? (Model.safeUrl(store, game.url) || Model.searchUrl(store))
      : Model.searchUrl(store)
    Qt.openUrlExternally(url)
    close()
  }

  function openSelected() {
    openGame(selectedGame())
  }

  // --- IPC ---------------------------------------------------------------

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    // Notification actions. Both take the store and game id as separate string
    // arguments; the widget validates them before touching state or a URL.
    function markSeen(store: string, id: string): void { root.markSeen(store, id) }
    function openGame(store: string, id: string): void { root.openGameById(store, id) }
  }

  // --- Processes ---------------------------------------------------------

  Process {
    id: loadSeenProc
    command: [root.python, root.seenStatePath, "load", root.stateDir]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.ingestSeen(text)
    }
    onExited: function(exitCode) {
      // A missing or unreadable seen.json is not primed, so the first fetch
      // records silently rather than announcing everything.
      root.ingestSeen("")
      root.refresh()
    }
  }

  Process {
    id: saveSeenProc
    property string payload: ""
    command: [root.python, root.seenStatePath, "save", root.stateDir]
    stdinEnabled: true
    onStarted: write(payload)
  }

  // One fetch process per store, so a slow store cannot hold up the others.
  Process {
    id: steamProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.publish("steam", text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.bucket("steam").busy)
        root.fail("steam", "Could not reach Steam")
    }
  }

  Process {
    id: epicProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.publish("epic", text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.bucket("epic").busy)
        root.failEpicPart("pc")
    }
  }

  Process {
    id: epicMobileAndroidProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.publishEpicMobile("android", text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.bucket("epic").busy)
        root.failEpicPart("android")
    }
  }

  Process {
    id: epicMobileIosProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.publishEpicMobile("ios", text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.bucket("epic").busy)
        root.failEpicPart("ios")
    }
  }

  Process {
    id: gogProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.publish("gog", text)
    }
    onExited: function(exitCode) {
      // curl -f exits non-zero on GOG's 404, which is the empty-giveaway
      // answer, so only a genuinely unreachable store reports an error.
      if (exitCode !== 0 && root.bucket("gog").busy)
        root.fail("gog", "Could not reach GOG")
    }
  }

  Process {
    id: amazonProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.publish("amazon", text)
    }
    onExited: function(exitCode) {
      // 127 is "command not found": the browser this store needs is absent.
      if (exitCode === 127 && root.bucket("amazon").busy)
        root.fail("amazon", "Chromium is required but was not installed")
      else if (exitCode !== 0 && root.bucket("amazon").busy)
        root.fail("amazon", "Could not reach Amazon Luna")
    }
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
    id: retryTimer
    interval: 30000
    onTriggered: root.refresh()
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
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
    tooltipText: Model.statusTitle(root.displayBuckets(), root.storesOn, root.anyBusy)
      + "\n" + Model.tooltipDetail(root.displayBuckets(), root.storesOn)
      + "\n" + root.freshness

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
    // The hero and the pinned footer are no longer part of the list's content,
    // so both are added back in to keep the card tall enough to hold them.
    // In the settings page the settings column stands in for the list.
    contentHeight: panel.fittedContentHeight(pinned.height
                                             + (root.showSettings
                                                 ? settingsPage.contentHeight
                                                 : panelList.contentHeight)
                                             + (root.showSettings
                                                 ? settingsFooter.implicitHeight
                                                 : panelFooter.implicitHeight),
                                             root.showSettings ? Style.space(900) : Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        // In Settings the list is not on screen, so its cursor must not
        // move (or highlight an invisible row).
        if (root.showSettings) return
        if (!root.cursorActive) {
          // The first move engages the cursor. When the pointer is highlighting
          // a game, that game is the base position and the step moves from it,
          // so shifting from the mouse to the keyboard continues where the
          // pointer left off. With no pointer, it lands on the edge of the list
          // in that direction, so j selects the first game rather than leaving
          // the highlight wherever the last refresh happened to pin it.
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

      // Enter and Space activate whatever the keyboard cursor is on. They must
      // stay silent until the cursor exists: selectedIndex is pinned to a game
      // on every fetch, but no row is shown as selected until the user presses
      // j/k or an arrow, so activating before then opened an arbitrary game
      // that had never been presented as the selection.
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
        // Game keys are inert in Settings; only r/v and the settings key act.
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
        if (key === "r") root.refresh()
        else if (key === "s") root.toggleHighlighted()
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

        // --- One row: a store header, or a game --------------------------
        delegate: Item {
          id: row
          required property var modelData
          required property int index
          width: panelList.width

          readonly property bool isHeader: modelData.kind === "header"
          readonly property bool isHidden: modelData.kind === "hidden"
          readonly property bool isEmpty: modelData.kind === "empty"
          readonly property bool isChecking: modelData.kind === "checking"

          // Whether this row's game has not been acknowledged, and whether its
          // giveaway is within a day of ending (or past its end but still
          // listed). Both guarded, so a header or a row without a game is
          // neither. endingSoon reads root.nowMs, so the always-on 30s tick
          // re-evaluates it without a timer of its own.
          readonly property bool unseen: !isHeader && !!modelData.game
            && root.gameUnseen(modelData.store, modelData.game.id)
          readonly property bool endingSoon: !isHeader && !!modelData.game
            && Model.endingSoon(modelData.game.endsAt, root.nowMs)

          // The switch draws its hover ring a few pixels outside its track, so
          // the header row must be at least as tall as the switch or the ring
          // is clipped — and the first store's ring, sitting at the top of the
          // list, had its top cut off by a flat 30px row. Deriving the height
          // from the switch keeps it whole without hard-coding a size that a
          // larger theme font would invalidate.
          readonly property int headerRowHeight: Style.space(30)

          // The empty-store note needs air below it. Without it the note
          // ended flush with its row and sat right on the list's trailing
          // spacing, which put it against the rule at the bottom.
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

          // Store header: mark, name and accent rule.
          Item {
            anchors.fill: parent
            visible: row.isHeader

            // Behind the controls, and accepting no buttons, so hovering the
            // header retargets the keyboard without eating the bell's clicks.
            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.NoButton
              hoverEnabled: true
              onEntered: root.targetStore = row.modelData.store
            }

            // The store's mark, in a fixed box so every header starts its label
            // at the same inset. Epic has no Nerd Font glyph, so it uses the
            // bundled logo, colorized to the theme; the rest are glyphs.
            Item {
              id: headerMark
              anchors.left: parent.left
              anchors.leftMargin: Style.space(24)
              anchors.verticalCenter: parent.verticalCenter
              width: root.markSize
              height: root.markSize

              Text {
                anchors.centerIn: parent
                visible: row.modelData.store !== "epic"
                textFormat: Text.PlainText
                text: Model.STORE_GLYPHS[row.modelData.store] || ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: root.markSize
              }

              Image {
                id: epicLogo
                anchors.fill: parent
                // Only the Epic header loads the asset; the same delegate is
                // reused for game rows, which must not read it.
                source: row.modelData.store === "epic"
                  ? root.pluginFile("assets/epic.svg") : ""
                fillMode: Image.PreserveAspectFit
                // Decode at physical pixels, as the shell's tray icons do, so
                // the small mark stays crisp on a scaled display.
                sourceSize.width: Math.round(width * Screen.devicePixelRatio)
                sourceSize.height: Math.round(height * Screen.devicePixelRatio)
                // Hidden but layered, so the effect can sample it as a texture.
                visible: false
                layer.enabled: row.modelData.store === "epic"
              }

              MultiEffect {
                anchors.fill: epicLogo
                source: epicLogo
                visible: row.modelData.store === "epic"
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
              // Regular text colour, bold, so the store pops above the
              // muted seen rows without competing with the accent markers.
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              font.letterSpacing: 1.0
              elide: Text.ElideRight
            }

            // Rules flanking the mark and name, centred on the row: one
            // from the window's left padding to the mark, one from the
            // name's right edge to the window's right padding.
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

          // Only a failure earns a line of its own. A store with no games just
          // shows its name, which is all the toggle needs.
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

          // A game.
          Rectangle {
            anchors.top: parent.top
            anchors.topMargin: row.isHeader ? Style.space(30) : 0
            anchors.left: parent.left
            anchors.right: parent.right
            height: titleRow.implicitHeight + Style.spacing.sm
            visible: row.modelData.kind === "game"
            radius: Style.cornerRadius
            // One highlight, owned by whichever input was used last: the
            // keyboard cursor while it is active, the pointer otherwise. They
            // never stack.
            color: (root.cursorActive ? root.selectedIndex === row.index
                                      : root.pointerIndex === row.index)
              ? (root.bar ? Style.selectedFillFor(root.bar.foreground, Commons.Color.accent)
                          : "transparent")
              : "transparent"

            // The marker for a game the user has not acknowledged, or one whose
            // giveaway is ending soon. Centred in the same mark-sized box
            // as the header mark, so the gutter reads as one column.
            Text {
              id: gameMark
              width: root.markSize
              horizontalAlignment: Text.AlignHCenter
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              visible: row.unseen || row.endingSoon
              textFormat: Text.PlainText
              text: row.endingSoon ? Model.HOURGLASS_GLYPH : Model.NEW_GAME_GLYPH
              color: row.endingSoon ? root.urgent : Commons.Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall

              // Declared inside the marker so the tooltip anchors over the glyph
              // rather than over the whole row. A row that is both ending and
              // unseen names both states, and the click clears the unseen one.
              PanelToolTip {
                visible: gameMouse.containsMouse && gameMouse.overGlyph
                text: row.endingSoon
                  ? (Model.endsInLabel(row.modelData.game.endsAt, root.nowMs)
                      + (row.unseen ? ". Mark as seen" : ""))
                  : "Mark as seen"
                fontFamily: root.fontFamily
              }
            }

            // Title plus, on Epic mobile rows, an interpunct and a larger
            // platform glyph immediately to its right. The glyph is scaled
            // up rather than set in a bigger font, so it reads bigger
            // without growing the row, and it sits in its own Text so it
            // cannot clip into the title.
            Row {
              id: titleRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: root.storeIndent
              anchors.rightMargin: Style.spacing.sm
              spacing: Style.space(4)

              // Titles from the network are plain text, never markup. A header
              // row has no `game`, and hiding a row does not stop this binding
              // being evaluated, so it is guarded rather than made invisible.
              // Width leaves room for the separator and glyph when shown, so
              // a long title elides in front of them instead of pushing
              // them off.
              Text {
                id: gameTitle
                width: Math.min(implicitWidth, parent.width
                  - (platformGroup.visible
                      ? separatorDot.implicitWidth
                        + platformGroup.implicitWidth * 1.4
                        + titleRow.spacing * 2 : 0))
                textFormat: Text.PlainText
                text: row.modelData.kind === "game" && row.modelData.game
                  ? row.modelData.game.title : ""
                // Seen games read muted next to the unseen ones, so the
                // eye can scan what is actually new.
                color: row.unseen ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Text {
                id: separatorDot
                anchors.verticalCenter: parent.verticalCenter
                visible: row.modelData.kind === "game" && !!row.modelData.game
                  && !!row.modelData.game.platform
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
                visible: row.modelData.kind === "game" && !!row.modelData.game
                  && !!row.modelData.game.platform
                textFormat: Text.PlainText
                text: row.modelData.kind === "game" && row.modelData.game
                  && row.modelData.game.platform
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
              // Whether the pointer is over the marker glyph. This drives the
              // tooltip whoever the glyph belongs to; the click uses it together
              // with `row.unseen`, so an already-seen game still explains its
              // hourglass on hover while its click falls through to launching.
              readonly property bool overGlyph: gameMark.visible
                && mouseX >= gameMark.x && mouseX <= gameMark.x + gameMark.width
              // The pointer picks the store the keyboard acts on, so e and n do
              // not depend on where the keyboard cursor happens to be.
              // Entering only records the pointer row: a row can enter under a
              // stationary pointer when a keypress scrolls the list, and
              // claiming the highlight there would yank the cursor back to
              // wherever the scroll left the pointer.
              onEntered: {
                if (Date.now() < root.hoverSuppressUntil) return
                root.pointerIndex = row.index
                root.targetStore = row.modelData.store
              }
              // Real pointer movement claims the highlight, dismissing the
              // keyboard cursor so the two do not both draw, and becomes the
              // base for the next j/k move. A row scrolling under a still
              // pointer also reports a position change, so only a change in the
              // pointer's scene point counts as movement.
              onPositionChanged: function(mouse) {
                if (Date.now() < root.hoverSuppressUntil) return
                if (!root.pointerMoved(mapToItem(null, mouse.x, mouse.y))) return
                root.pointerIndex = row.index
                root.cursorActive = false
                root.targetStore = row.modelData.store
              }
              // Leaving the rows clears the highlight: the pointer took it from
              // the keyboard, so the keyboard's position does not come back.
              onExited: if (root.pointerIndex === row.index) root.pointerIndex = -1
              // One MouseArea covers the whole row, including the marker, so
              // moving onto the glyph cannot exit-and-clear the highlight. A
              // click on the marker of an unseen game marks it seen; anywhere
              // else launches it. Marking an already-seen game would be a no-op,
              // so there the hourglass click launches instead.
              onClicked: {
                if (overGlyph && row.unseen)
                  root.markSeen(row.modelData.store, row.modelData.game.id)
                else root.openGame(row.modelData)
              }
            }
          }

          // Where seen games are hidden, the summary stands in for them, so a
          // store whose games are all seen still says why its list is short.
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
              ? Model.hiddenSeenLabel(row.modelData.count, row.modelData.endingSoon) : ""
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

          // A freshly enabled store that is still fetching says so, so
          // the wait reads as progress rather than lag.
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

          // No free giveaways anywhere: a sad glyph and the plain message,
          // so an empty panel is a statement rather than a blank card.
          Row {
            id: emptyNote
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)
            visible: row.isEmpty

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              // U+F119 (fa-face-frown in Nerd Fonts 3.5.1): a plain
              // downturned mouth that reads as sad at row size. The
              // crying-face marks look like the Android robot down here.
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

      // Settings page: every preference in one place, grouped by store.
      // Shares the list's slot; the hero and footer stay pinned.
      ListView {
        id: settingsPage
        visible: root.showSettings
        anchors.top: pinned.bottom
        anchors.bottom: settingsFooter.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.spacing.sm
        anchors.rightMargin: Style.spacing.sm
        clip: true
        model: root.settingsRows()
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
          width: settingsPage.width
          readonly property bool isHeading: modelData.kind === "heading"
          // Layout height per kind, so contentHeight is real before layout.
          // Every non-heading row uses the control height, giving the
          // General section the same tight rhythm as the store sections
          // while still clearing a dropdown's hover border.
          height: isHeading ? Style.font.caption + Style.space(24)
            : Style.spacing.controlHeight

          Text {
            id: settingLabel
            anchors.left: parent.left
            // Setting rows sit indented under their store heading, the
            // same way game rows sit under a store header. Headings sit
            // clear of their mark.
            anchors.leftMargin: settingRow.isHeading
              ? Style.space(24) + root.markSize + Style.space(8) : root.storeIndent
            anchors.verticalCenter: parent.verticalCenter
            visible: settingRow.isHeading || modelData.kind === "country"
            // A country label sizes to its text so the field sits
            // directly beside it instead of at the row's far edge.
            // Labels size to their text so the flanking rule on the right
            // starts right after the name; the country label fills the
            // shared column so its field starts on the same x as every
            // other control.
            width: modelData.kind === "country"
              ? root.settingsLabelColumn : implicitWidth
            textFormat: Text.PlainText
            text: settingRow.isHeading
              ? (modelData.label || "").toUpperCase()
              : ((modelData.label || "") + ":")
            // Headings carry the same treatment as the store names in the
            // main list: regular text colour, bold, at body size.
            color: settingRow.isHeading ? root.foreground : root.foreground
            font.family: root.fontFamily
            font.pixelSize: settingRow.isHeading ? Style.font.body : Style.font.bodySmall
            font.bold: settingRow.isHeading
            font.letterSpacing: settingRow.isHeading ? 1.0 : 0
            elide: Text.ElideRight
          }

          // The store's mark beside its Settings heading, matching the
          // main list (Epic uses its bundled logo).
          Item {
            id: settingMark
            anchors.left: parent.left
            anchors.leftMargin: Style.space(24)
            anchors.verticalCenter: parent.verticalCenter
            width: root.markSize
            height: root.markSize
            visible: settingRow.isHeading

            Text {
              anchors.centerIn: parent
              visible: !!modelData.store && modelData.store !== "epic"
              textFormat: Text.PlainText
              text: Model.STORE_GLYPHS[modelData.store] || ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: root.markSize
            }

            Text {
              anchors.centerIn: parent
              visible: !modelData.store
              textFormat: Text.PlainText
              text: "\u{F0AD}"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: root.markSize
            }

            Image {
              id: settingEpicLogo
              anchors.fill: parent
              source: modelData.store === "epic"
                ? root.pluginFile("assets/epic.svg") : ""
              fillMode: Image.PreserveAspectFit
              sourceSize.width: Math.round(width * Screen.devicePixelRatio)
              sourceSize.height: Math.round(height * Screen.devicePixelRatio)
              visible: false
              layer.enabled: modelData.store === "epic"
            }

            MultiEffect {
              anchors.fill: settingEpicLogo
              source: settingEpicLogo
              visible: modelData.store === "epic"
              colorization: 1.0
              colorizationColor: root.dim
            }
          }

          // The same flanking rules as the main list: one from the window's
          // left padding to the mark, one from the name's right edge to the
          // right padding.
          PanelSeparator {
            visible: settingRow.isHeading
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.sm
            anchors.right: settingMark.left
            anchors.rightMargin: Style.space(8)
            foreground: root.foreground
            height: Style.space(2)
          }
          PanelSeparator {
            visible: settingRow.isHeading
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: settingLabel.right
            anchors.leftMargin: Style.space(8)
            anchors.right: parent.right
            foreground: root.foreground
            height: Style.space(2)
          }

          // A lone toggle (Hide seen games) sits with its switch at the
          // same left edge as the store switches, so every toggle, dropdown
          // and input in the page lines up in one column.
          Row {
            anchors.left: parent.left
            anchors.leftMargin: root.storeIndent
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.settingsGap
            visible: modelData.kind === "toggle"

            Text {
              width: root.settingsLabelColumn
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: (modelData.label || "") + ":"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            // Wrapped so the switch's cursor-ring inset does not push the
            // visible track right of the dropdown/input column below it.
            Item {
              width: generalToggle.implicitWidth - root.settingsTogglePad
              height: generalToggle.implicitHeight
              anchors.verticalCenter: parent.verticalCenter

              ToggleSwitch {
                id: generalToggle
                x: -root.settingsTogglePad
                anchors.verticalCenter: parent.verticalCenter
                checked: root.settingsToggleChecked(modelData)
                foreground: root.foreground
                accent: Commons.Color.accent
                onToggled: root.settingsToggleFlip(modelData)
              }
            }
          }

          // Condensed store row: Enabled and Notifications on one line,
          // each control at a fixed column so the two switch stacks line
          // up down the whole page.
          Row {
            anchors.left: parent.left
            anchors.leftMargin: root.storeIndent
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.settingsGap
            visible: modelData.kind === "store"

            Text {
              width: root.settingsStoreLabel1
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "Enabled:"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            ToggleSwitch {
              anchors.verticalCenter: parent.verticalCenter
              checked: root.storesOn[modelData.store] === true
              foreground: root.foreground
              accent: Commons.Color.accent
              onToggled: root.toggleStore(modelData.store)
            }
            Item {
              width: root.settingsCol2X
                - root.settingsStoreLabel1 - root.settingsGap
                - root.settingsToggleWidth - root.settingsGap
            }
            Text {
              width: root.settingsStoreLabel2
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "Notifications:"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            ToggleSwitch {
              anchors.verticalCenter: parent.verticalCenter
              checked: root.notifyOn[modelData.store] === true
              foreground: root.foreground
              accent: Commons.Color.accent
              onToggled: root.toggleBell(modelData.store)
            }
          }

          // Epic platforms row: Android and iOS on one line, in the same
          // two columns as Enabled and Notifications above it.
          Row {
            anchors.left: parent.left
            anchors.leftMargin: root.storeIndent
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.settingsGap
            visible: modelData.kind === "platforms"

            Text {
              width: root.settingsStoreLabel1
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "Android:"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            ToggleSwitch {
              anchors.verticalCenter: parent.verticalCenter
              checked: root.epicMobileOn.android === true
              foreground: root.foreground
              accent: Commons.Color.accent
              onToggled: root.toggleEpicMobile("android")
            }
            Item {
              width: root.settingsCol2X
                - root.settingsStoreLabel1 - root.settingsGap
                - root.settingsToggleWidth - root.settingsGap
            }
            Text {
              width: root.settingsStoreLabel2
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "iOS:"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            ToggleSwitch {
              anchors.verticalCenter: parent.verticalCenter
              checked: root.epicMobileOn.ios === true
              foreground: root.foreground
              accent: Commons.Color.accent
              onToggled: root.toggleEpicMobile("ios")
            }
          }
          // Sensible dropdown for both ranged settings, with a Custom
          // entry that reveals a numeric-only input for schema-valid
          // values between the presets. The current value always shows:
          // if it is not a preset, Custom is selected and the input
          // carries it.
          Row {
            id: rangeRow
            anchors.left: parent.left
            anchors.leftMargin: root.storeIndent
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.settingsGap
            visible: modelData.kind === "sliderRefresh" || modelData.kind === "sliderNotify"

            Text {
              width: root.settingsLabelColumn
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: modelData.kind === "sliderRefresh"
                ? "Refresh interval (min):" : "Store notification limit:"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Dropdown {
              id: rangeDropdown
              width: root.settingsControlWidth
              label: ""
              showLabel: false
              value: {
                var cur = modelData.kind === "sliderRefresh"
                  ? root.refreshMinutes : root.maxStoreNotifications
                var presets = modelData.kind === "sliderRefresh"
                  ? [30, 45, 60, 90, 120, 240, 360]
                  : [0, 1, 2, 3, 4, 5]
                return presets.indexOf(cur) >= 0 ? String(cur) : "custom"
              }
              options: modelData.kind === "sliderRefresh"
                ? [{ value: "30", label: "30m" }, { value: "45", label: "45m" },
                   { value: "60", label: "1h" }, { value: "90", label: "1.5h" },
                   { value: "120", label: "2h" }, { value: "240", label: "4h" },
                   { value: "360", label: "6h" },
                   { value: "custom", label: "Custom" }]
                : [{ value: "0", label: "No limit" }, { value: "1", label: "1" },
                   { value: "2", label: "2" }, { value: "3", label: "3" },
                   { value: "4", label: "4" }, { value: "5", label: "5" },
                   { value: "custom", label: "Custom" }]
              foreground: root.foreground
              fontFamily: root.fontFamily
              // Shown as text, never the raw value, so a non-preset
              // current value still reads as Custom in the trigger.
              property bool customSelected: false
              onChanged: {
                rangeDropdown.customSelected = value === "custom"
                if (value !== "custom") {
                  if (modelData.kind === "sliderRefresh")
                    root.persist({ refreshMinutes: Model.normalizeRefreshMinutes(Number(value)) })
                  else
                    root.persist({ maxStoreNotifications: Model.normalizeMaxStoreNotifications(Number(value)) })
                }
              }
              Component.onCompleted: rangeDropdown.customSelected =
                (modelData.kind === "sliderRefresh"
                  ? [30, 45, 60, 90, 120, 240, 360]
                  : [0, 1, 2, 3, 4, 5]).indexOf(
                    modelData.kind === "sliderRefresh"
                      ? root.refreshMinutes : root.maxStoreNotifications) < 0
            }

            TextField {
              id: customField
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(52)
              height: Style.spacing.controlHeight
              verticalPadding: Style.spacing.controlPaddingY
              visible: rangeDropdown.customSelected
              text: String(modelData.kind === "sliderRefresh"
                ? root.refreshMinutes : root.maxStoreNotifications)
              font.family: root.fontFamily
              placeholderText: modelData.kind === "sliderRefresh" ? "30–720" : "0–20"
              onAccepted: {
                var v = String(text).trim()
                if (!/^\d+$/.test(v)) { text = String(
                  modelData.kind === "sliderRefresh"
                    ? root.refreshMinutes : root.maxStoreNotifications); return }
                var n = Number(v)
                if (modelData.kind === "sliderRefresh")
                  root.persist({ refreshMinutes: Model.normalizeRefreshMinutes(n) })
                else
                  root.persist({ maxStoreNotifications: Model.normalizeMaxStoreNotifications(n) })
                Qt.callLater(function() { keyCatcher.forceActiveFocus() })
              }
              onEditingFinished: {
                var v2 = String(text).trim()
                if (/^\d+$/.test(v2)) {
                  var n2 = Number(v2)
                  if (modelData.kind === "sliderRefresh")
                    root.persist({ refreshMinutes: Model.normalizeRefreshMinutes(n2) })
                  else
                    root.persist({ maxStoreNotifications: Model.normalizeMaxStoreNotifications(n2) })
                }
                text = String(modelData.kind === "sliderRefresh"
                  ? root.refreshMinutes : root.maxStoreNotifications)
                Qt.callLater(function() { keyCatcher.forceActiveFocus() })
              }
            }
          }

          TextField {
            anchors.left: parent.left
            anchors.leftMargin: root.storeIndent + root.settingsLabelColumn
              + root.settingsGap
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(70)
            height: Style.spacing.controlHeight
            verticalPadding: Style.spacing.controlPaddingY
            visible: modelData.kind === "country"
            text: root.country
            placeholderText: "US, DE, GB…"
            font.family: root.fontFamily
            // Leaving the field returns keyboard focus to the panel, or
            // keybinds like "s" keep typing into the box afterwards.
            onAccepted: {
              root.persist({ country: Model.normalizeCountry(text) })
              Qt.callLater(function() { keyCatcher.forceActiveFocus() })
            }
            onEditingFinished: {
              var clean = Model.normalizeCountry(text)
              if (clean !== root.country) root.persist({ country: clean })
              text = root.country
              Qt.callLater(function() { keyCatcher.forceActiveFocus() })
            }
          }
        }
      }

      // The scrollbar auto-hides, so a fade and a chevron at an edge say there
      // is more content in that direction. The fade uses the surface colour and
      // fades to the same RGB at zero alpha, so it works over rows and
      // highlights alike; the chevron keeps the hint visible even when a gap
      // between rows leaves nothing behind the fade to darken.
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

      // The settings list gets the same edge hints, but only once it is
      // actually tall enough to scroll — the store list's fades belong to
      // the store list.
      Rectangle {
        id: settingsTopFade
        anchors.top: settingsPage.top
        anchors.left: settingsPage.left
        anchors.right: settingsPage.right
        height: Style.space(30)
        visible: root.showSettings && settingsPage.interactive && !settingsPage.atYBeginning
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

      Rectangle {
        id: settingsBottomFade
        anchors.bottom: settingsPage.bottom
        anchors.left: settingsPage.left
        anchors.right: settingsPage.right
        height: Style.space(30)
        visible: root.showSettings && settingsPage.interactive && !settingsPage.atYEnd
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
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // --- Pinned footer -----------------------------------------------
      // Outside the list, so the games scroll between the hero's rule and this
      // one instead of carrying the controls off-screen.
      Column {
        id: panelFooter
        visible: !root.showSettings
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        // Tighter than the panel's usual gap: the footer is a block of small
        // controls, and panelGap left a visible hole between them.
        spacing: Style.space(6)
        // Clearance above the rule, matching the gap under the hero's rule, so
        // the last game row is not flush against the footer.
        topPadding: Style.space(8)

        // When nothing is watched, this one centred line stands alone.
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

        // A rule between the list and the controls, so the buttons are not
        // read as part of a store's rows. The gap above it is the footer's
        // own topPadding, and the gap below the hero's rule is the same size,
        // so both sides of the rule match.
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
          text: "r refresh · s toggle seen · v hide/show seen · , settings · j/k scroll · enter open"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // The very last row: refresh and the seen-eye in the near corner,
        // the settings gear and help in the far one, and the freshness
        // centred between them.
        //
        // The text is centred with anchors rather than by filling the row and
        // centring within it, so no button can shift it off centre. Its width
        // is capped at whatever is left between them, which keeps a long
        // freshness string from running under a button.
        Item {
          width: parent.width
          implicitHeight: Math.max(centerColumn.implicitHeight,
                                   refreshButton.implicitHeight,
                                   seenButton.implicitHeight,
                                   gearButton.implicitHeight,
                                   helpButton.implicitHeight)

          // Centre stack between the button clusters: disabled-store
          // summary above the freshness, both centred.
          Column {
            id: centerColumn
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
              - refreshButton.implicitWidth
              - seenButton.implicitWidth
              - gearButton.implicitWidth
              - helpButton.implicitWidth - Style.space(20)
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
              text: root.freshness
              color: root.stale ? root.dim : root.footerInk
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

          // Eye: hide or show the games already marked seen. Like the bell it
          // swaps glyph and tooltip with the state it is in. Fixed to the
          // same size as Refresh, so the whole footer reads as one row of
          // equal boxes.
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

          // Gear: open the in-panel settings page.
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

      // In Settings the store-list footer does not apply (Refresh acts on
      // stores, the eye on the list), so it is swapped for a single
      // centred way back.
      Column {
        id: settingsFooter
        visible: root.showSettings
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
          foreground: root.foreground
        }

        Item {
          width: parent.width
          implicitHeight: refreshButton.implicitHeight

          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            text: "Exit Settings"
            bordered: true
            foreground: root.footerInk
            accent: Commons.Color.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            tooltipText: "Back to the store list"
            onClicked: {
              root.showSettings = false
              Qt.callLater(function() { keyCatcher.forceActiveFocus() })
            }
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
