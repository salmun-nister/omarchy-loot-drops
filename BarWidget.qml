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
  readonly property int refreshMinutes:
    // undefined, not 0: an absent setting must land on the default, and 0 would
    // clamp to the floor instead.
    Model.normalizeRefreshMinutes(setting("refreshMinutes", undefined))
  readonly property string steamCountry: Model.normalizeCountry(setting("steamCountry", ""))
  // Whether the panel hides games already marked seen. This is a view filter,
  // not a second baseline: the seen state itself is untouched.
  readonly property bool hideSeen: setting("hideSeen", false)

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
  // Whichever store the e and n keys act on. It follows the pointer when the
  // pointer is over a row, and the keyboard cursor otherwise, so pressing e
  // acts on the store you are looking at rather than on whichever one happens
  // to be first.
  property string targetStore: ""
  // Whether the panel is currently showing the keyboard shortcuts.
  property bool showShortcuts: false

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
      if (storesOn[store] === true) out[store] = bucket(store)
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
  // the cursor is a plain index and a row can be fetched by position to scroll
  // it into view.
  //
  // A store that is switched off still gets a header, so it can be switched
  // back on from the panel, but its games are dropped: an unwatched store
  // contributes nothing to the list and its header renders faded.
  function visibleGameList() {
    var list = []
    for (var i = 0; i < Model.STORES.length; i++) {
      var store = Model.STORES[i]
      var on = storesOn[store] === true
      var current = bucket(store)
      list.push({
        kind: "header",
        store: store,
        enabled: on,
        empty: on && (!current.games || current.games.length === 0),
        failed: on && !!current.error,
        errorLabel: on ? Model.storeErrorLabel(store, errorsByStore()) : ""
      })
      if (!on) continue
      var shown = current.games
      var hidden = 0
      if (hideSeen) {
        var split = Model.splitSeenGames(current.games,
          Model.acknowledgedOf(seenState, store))
        shown = split.shown
        hidden = split.hidden
      }
      for (var j = 0; j < shown.length; j++) {
        list.push({ kind: "game", store: store, game: shown[j] })
      }
      // The summary is the store's last entry, so every unseen game reads first.
      if (hidden > 0) list.push({ kind: "hidden", store: store, count: hidden })
    }
    return list
  }

  // Write a setting change back to this widget's entry in shell.json. Applied
  // locally first so the switch moves on the click itself, then persisted; the
  // bar feeds the same value back through settings a moment later. This is the
  // same pattern Omarchy's own Tray and Clock widgets use.
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
    if (root.bar && root.bar.shell
        && typeof root.bar.shell.updateEntryInline === "function") {
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    }
  }

  function enabledKey(store) { return store + "Enabled" }
  function notifyKey(store) { return store + "Notify" }

  // Switching a store off stops it being fetched at all; switching it back on
  // re-records silently rather than announcing everything it missed.
  function toggleStore(store) {
    targetStore = store
    persist({ [enabledKey(store)]: !storesOn[store] })
    reanchorCursor()
  }

  function toggleBell(store) {
    targetStore = store
    persist({ [notifyKey(store)]: !notifyOn[store] })
  }

  // The eye hides games the user has already marked seen. Persisted like the
  // switches and bells so it survives a restart.
  function toggleHideSeen() {
    persist({ hideSeen: !hideSeen })
    reanchorCursor()
  }

  function toggleSelectedStore() {
    var store = cursorStore()
    if (store) toggleStore(store)
  }

  function toggleSelectedBell() {
    var store = cursorStore()
    if (store) toggleBell(store)
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
      if (bucket(Model.STORES[i]).error) return true
    }
    return false
  }

  // Acknowledge one game, clearing its marker and letting the bar dot go out
  // once every new game has been marked.
  function markSeen(store, id) {
    if (!seenLoaded) return
    seenState = Model.acknowledgeGame(seenState, store, id)
    persistSeen()
    // With seen games hidden, marking one removes its row underneath the
    // cursor, so re-anchor rather than leaving a stale index behind.
    reanchorCursor()
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
    seenState = gameUnseen(store, id)
      ? Model.acknowledgeGame(seenState, store, id)
      : Model.forgetGame(seenState, store, id)
    persistSeen()
    reanchorCursor()
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
    var proc = fetchProcs[store]
    proc.command = [root.python, root.cappedRun, String(Model.MAX_BYTES)]
      .concat(fetchArgs(store))
    proc.running = true
    updateBusy()
  }

  function fetchArgs(store) {
    // Amazon is rendered rather than requested, so a browser is its transport.
    if (store === "amazon") return amazonArgs()
    var deadlineSeconds = Math.ceil(fetchDeadlineMs / 1000)
    return [
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
      "--write-out", "\n%{http_code}",
      sourceUrl(store)
    ]
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
      var cc = steamCountry
      return cc ? url + "&cc=" + encodeURIComponent(cc) : url
    }
    if (store === "epic") {
      return "https://store-site-backend-static.ak.epicgames.com/freeGamesPromotions"
        + "?locale=en-US&country=US&allowCountries=US"
    }
    if (store === "amazon") return Model.SEARCH_URLS.amazon
    return "https://www.gog.com/giveaway/api/get"
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
      fail(store, "Store returned an unexpected response")
      return
    }
    succeed(store, parsed.games)
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

    var argv = Model.notificationArgs(store, transition.alerts)
    if (argv) Quickshell.execDetached(argv)

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

  // The store the keyboard acts on: whichever store the cursor last landed on.
  //
  // It is deliberately NOT re-derived from the current selection. Switching a
  // store off removes its rows, which re-anchors the cursor onto a different
  // store's game, so deriving from the selection would make a second press of e
  // toggle some other store. The remembered value only changes when the user
  // moves the cursor or clicks a row, which is what "twice on the same game"
  // has to mean.
  function cursorStore() {
    if (targetStore) return targetStore
    var row = selectedGame()
    if (!row) return ""
    targetStore = row.store
    return row.store
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
        root.fail("epic", "Could not reach Epic")
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
    tooltipText: Model.statusTitle(root.buckets, root.storesOn, root.anyBusy)
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
    contentHeight: panel.fittedContentHeight(pinned.height
                                             + panelList.contentHeight
                                             + panelFooter.implicitHeight,
                                             Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
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
      onActivateRequested: if (root.cursorActive) root.openSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        var key = text.toLowerCase()
        if (key === "r") root.refresh()
        else if (key === "e") root.toggleSelectedStore()
        else if (key === "n") root.toggleSelectedBell()
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
            Text {
              width: parent.width
              textFormat: Text.PlainText
              visible: text !== ""
              text: Model.heroDetail(root.buckets, root.storesOn).toUpperCase()
              color: Qt.darker(hero.tint, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
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
          readonly property int headerRowHeight:
            Math.max(headerSwitch.implicitHeight, Style.space(30))

          // The empty-store note needs air below it. Without it the note
          // ended flush with its row and sat right on the list's trailing
          // spacing, which put it against the rule at the bottom.
          implicitHeight: isHeader
            ? headerRowHeight
              + (modelData && modelData.errorLabel
                ? storeError.implicitHeight + Style.space(8) : 0)
            : isHidden
              ? hiddenNote.implicitHeight + Style.spacing.sm
              : gameTitle.implicitHeight + Style.spacing.sm

          // Store header: mark, name, bell, switch.
          Item {
            anchors.fill: parent
            visible: row.isHeader
            // A store that is switched off reads as present but inactive.
            opacity: row.isHeader && row.modelData.enabled === false ? 0.45 : 1

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
              anchors.leftMargin: Style.spacing.sm
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
              // Room for the bell and the switch; the bell contributes nothing
              // when it is hidden.
              width: parent.width - (headerBell.visible ? headerBell.width : 0)
                     - headerSwitch.width - Style.spacing.sm * 3
              textFormat: Text.PlainText
              text: Model.STORE_LABELS[row.modelData.store] || ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.0
              elide: Text.ElideRight
            }

            // Bell button: mute or unmute this store's notifications.
            // Hidden while the store is off, since there is nothing to mute.
            //
            // A bordered Button, the same kind the footer's Refresh and ? are,
            // so the three read as one sort of control and share the outline,
            // hover fill and tooltip rather than the bell being a bare glyph
            // with its own hand-rolled hover box.
            Button {
              id: headerBell
              visible: row.modelData.enabled !== false
              anchors.right: headerSwitch.left
              anchors.rightMargin: Style.spacing.xs
              anchors.verticalCenter: parent.verticalCenter
              text: root.notifyOn[row.modelData.store]
                ? "\u{F0F3}" : "\u{F1F6}"
              bordered: true
              foreground: root.notifyOn[row.modelData.store]
                ? root.dim : Qt.darker(root.dim, 1.4)
              accent: Commons.Color.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              tooltipText: root.notifyOn[row.modelData.store]
                ? "Mute notifications" : "Unmute notifications"
              onClicked: root.toggleBell(row.modelData.store)
            }

            // Switch: stop or resume watching this store entirely.
            ToggleSwitch {
              id: headerSwitch
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              checked: root.storesOn[row.modelData.store] === true
              foreground: root.foreground
              accent: Commons.Color.accent
              onToggled: root.toggleStore(row.modelData.store)

              PanelToolTip {
                visible: headerSwitch.containsMouse
                text: (root.storesOn[row.modelData.store]
                  ? "Stop watching " : "Watch ")
                  + (Model.STORE_LABELS[row.modelData.store] || "this store")
                fontFamily: root.fontFamily
              }
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
            height: gameTitle.implicitHeight + Style.spacing.sm
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
            // giveaway is ending soon. It sits in the left gutter, aligned with
            // the store's own mark, so the title keeps its indent and nothing
            // shifts as markers clear. When both apply the hourglass wins and
            // the coin is withheld; the game stays unacknowledged underneath.
            Text {
              id: gameMark
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
                  ? (row.unseen ? "Ending soon. Mark as seen" : "Ending soon")
                  : "Mark as seen"
                fontFamily: root.fontFamily
              }
            }

            Text {
              id: gameTitle
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              // Indented under the store name so the two levels read apart.
              anchors.leftMargin: root.storeIndent
              anchors.rightMargin: Style.spacing.sm
              // Titles from the network are plain text, never markup. A header
              // row has no `game`, and hiding a row does not stop this binding
              // being evaluated, so it is guarded rather than made invisible.
              textFormat: Text.PlainText
              text: row.modelData.kind === "game" && row.modelData.game
                ? row.modelData.game.title : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
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
                root.pointerIndex = row.index
                root.targetStore = row.modelData.store
              }
              // Real pointer movement claims the highlight, dismissing the
              // keyboard cursor so the two do not both draw, and becomes the
              // base for the next j/k move. A row scrolling under a still
              // pointer also reports a position change, so only a change in the
              // pointer's scene point counts as movement.
              onPositionChanged: function(mouse) {
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
              ? Model.hiddenSeenLabel(row.modelData.count) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
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
        visible: panelList.interactive && !panelList.atYBeginning
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
        visible: panelList.interactive && !panelList.atYEnd
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
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        // Tighter than the panel's usual gap: the footer is a block of small
        // controls, and panelGap left a visible hole between them.
        spacing: Style.space(6)
        // Clearance above the rule, matching the gap under the hero's rule, so
        // the last game row is not flush against the footer.
        topPadding: Style.space(8)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          visible: root.activeStores.length === 0
          wrapMode: Text.WordWrap
          text: "Every store is switched off. Turn one on with the switch above to start watching."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
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
          text: "r refresh · e enable/disable store · n mute/unmute notifications · s toggle seen · v hide/show seen · j/k scroll · enter open"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // The very last row: refresh in the near corner, the seen toggle and
        // help in the far one, and the freshness centred between them.
        //
        // The text is centred with anchors rather than by filling the row and
        // centring within it, so no button can shift it off centre. Its width
        // is capped at whatever is left between them, which keeps a long
        // freshness string from running under a button.
        Item {
          width: parent.width
          implicitHeight: Math.max(bottomText.implicitHeight,
                                   refreshButton.implicitHeight,
                                   seenButton.implicitHeight,
                                   helpButton.implicitHeight)

          Text {
            id: bottomText
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, parent.width
                            - refreshButton.implicitWidth
                            - seenButton.implicitWidth
                            - helpButton.implicitWidth - Style.space(20))
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: root.freshness
            color: root.stale ? root.dim : root.footerInk
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
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
          // swaps glyph and tooltip with the state it is in.
          Button {
            id: seenButton
            anchors.right: helpButton.left
            anchors.rightMargin: Style.spacing.xs
            anchors.verticalCenter: parent.verticalCenter
            text: root.hideSeen ? "\u{F070}" : "\u{F06E}"
            bordered: true
            foreground: root.hideSeen ? root.footerInk
                                      : Qt.darker(root.footerInk, 1.35)
            accent: Commons.Color.accent
            fontFamily: root.fontFamily
            tooltipText: root.hideSeen ? "Show seen games" : "Hide seen games"
            onClicked: root.toggleHideSeen()
          }

          Button {
            id: helpButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
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

  onOpenedChanged: if (opened) {
    cursorActive = false
    pointerIndex = -1
    targetStore = ""
    showShortcuts = false
    nowMs = Date.now()
    // Opening the panel refreshes when the data is missing or stale, which is
    // what makes a long refresh interval safe to live with.
    if (lastSuccessAt === 0 || stale) refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
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
