pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
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

// Watch Steam, Epic and GOG for games that are free to keep. Parsing, URL
// allowlisting, seen-id transitions and notification copy live in Model.js;
// this file owns transport, persistence and rendering.
//
// The bar widget is always loaded, so it owns the refresh timer itself. There
// is deliberately no service kind: a process-wide singleton would be a second
// owner of the same timer for no gain.
Panel {
  id: root
  moduleName: "salmun-nister.loot-lightning"
  ipcTarget: "salmun-nister.loot-lightning"
  manageIpc: false

  readonly property string stateDir:
    Quickshell.env("LOOT_LIGHTNING_STATE")
    || ((Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
        + "/salmun-nister.loot-lightning")

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

  readonly property var storesOn: Model.enabled({
    "steamEnabled": setting("steamEnabled", true),
    "epicEnabled": setting("epicEnabled", true),
    "gogEnabled": setting("gogEnabled", true)
  })
  readonly property var notifyOn: Model.notifyFor({
    "steamNotify": setting("steamNotify", true),
    "epicNotify": setting("epicNotify", true),
    "gogNotify": setting("gogNotify", true)
  })
  readonly property int refreshMinutes:
    Model.normalizeRefreshMinutes(setting("refreshMinutes", 180))
  readonly property string steamCountry: Model.normalizeCountry(setting("steamCountry", ""))

  // Per-store results. Each bucket keeps its own games, error and timestamp so
  // one store failing never blanks the other two.
  property var buckets: ({
    "steam": newBucket(),
    "epic": newBucket(),
    "gog": newBucket()
  })

  property var seenState: Model.emptySeen()
  property bool seenLoaded: false
  property bool anyBusy: false
  property double lastSuccessAt: 0
  property double nowMs: Date.now()
  property int retryDelayMs: 30000
  property bool cursorActive: false
  property int selectedIndex: 0
  // Whichever store the e and n keys act on. It follows the pointer when the
  // pointer is over a row, and the keyboard cursor otherwise, so pressing e
  // acts on the store you are looking at rather than on whichever one happens
  // to be first.
  property string targetStore: ""
  // Whether the panel is currently showing the keyboard shortcuts.
  property bool showShortcuts: false

  readonly property bool stale: lastSuccessAt > 0
    && nowMs - lastSuccessAt >= Model.STALE_AFTER_MS
  readonly property string freshness: Model.freshnessLabel(
    lastSuccessAt, nowMs, anyBusy)
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
      height: panelList.height
    }
  }

  function rowsLaidOut() {
    var m = listMetrics()
    if (m.count === 0) return false
    return m.contentHeight > 0 && m.height > 0
  }

  // The row list contains a header per store, so its length is not a count of
  // games. Count the game rows only, or the bar mark would stop dimming
  // whenever a store is merely switched on.
  readonly property bool hasGames: gameCount() > 0

  // Games on offer that the panel has not been opened to show yet. Independent
  // of notifications: a muted store still has something you have not looked at.
  readonly property bool hasUnseen: Model.hasUnseen(seenState, buckets)

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
        stateLabel: on ? Model.storeStateLabel(store, current, errorsByStore()) : ""
      })
      if (!on) continue
      for (var j = 0; j < current.games.length; j++) {
        list.push({ kind: "game", store: store, game: current.games[j] })
      }
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

  function acknowledgeCurrent() {
    if (!seenLoaded) return
    seenState = Model.acknowledge(seenState, buckets)
    persistSeen()
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
    return "https://www.gog.com/giveaway/api/get"
  }

  // curl's -f makes a 404 an error exit, but GOG's 404 means "no giveaway
  // running" rather than a failure. The body is empty in that case, so the
  // store is reported healthy and empty.
  function publish(store, raw) {
    var body = String(raw || "")
    var code = "200"
    var split = body.lastIndexOf("\n")
    if (split >= 0) {
      code = body.slice(split + 1).trim()
      body = body.slice(0, split)
    }

    if (code === "404" && store === "gog") {
      succeed(store, [])
      return
    }

    var parsed = Model.parseStore(store, body)
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

  // The cursor walks game rows only, skipping headers, and never leaves the
  // viewport: the selected row is fetched from the Repeater and scrolled to.
  function gameCount() {
    var n = 0
    for (var i = 0; i < visibleGames.length; i++) {
      if (visibleGames[i].kind === "game") n++
    }
    return n
  }

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
    // safeUrl refuses anything off the store's own host, and the search page is
    // the fallback, so a row always opens somewhere legitimate.
    var url = Model.safeUrl(row.store, row.game.url) || Model.searchUrl(row.store)
    Quickshell.execDetached(["omarchy-launch-browser", url])
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

  readonly property var fetchProcs: ({
    "steam": steamProc,
    "epic": epicProc,
    "gog": gogProc
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
    tooltipText: (root.hasUnseen
      ? "New free games — click to see them\n"
      : "") + Model.statusTitle(root.buckets, root.storesOn, root.anyBusy)
      + "\n" + root.freshness

    onPressed: function(buttonCode) {
      // Left opens the panel, middle refreshes. Right-click is deliberately
      // unused so it cannot open anything behind the user's back.
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // The unseen marker, drawn over the bolt rather than beside it: a bar that
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
    contentHeight: panel.fittedContentHeight(panelList.contentHeight,
                                             Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) {
          root.cursorActive = true
          return
        }
        if (dy !== 0) root.moveCursor(dy)
      }

      onActivateRequested: root.openSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        var key = text.toLowerCase()
        if (key === "r") root.refresh()
        else if (key === "e") root.toggleSelectedStore()
        else if (key === "n") root.toggleSelectedBell()
        else if (key === "?") root.showShortcuts = !root.showShortcuts
      }

      // A ListView rather than a Column of Repeater rows. A Repeater builds its
      // items but never lays them out, so every row sat at y = 0 with the
      // enclosing Column reporting an implicit height of zero: the panel rendered
      // blank while the data underneath was correct. A ListView also gives
      // positionViewAtIndex, which is what keeps the cursor visible.
      ListView {
        id: panelList
        anchors.fill: parent
        clip: true
        model: root.visibleGames
        boundsBehavior: Flickable.StopAtBounds
        spacing: Style.spacing.xs

        ScrollBar.vertical: ScrollBar {
          policy: ScrollBar.AsNeeded
        }

        // --- Above the list ---------------------------------------------
        header: Column {
          width: panelList.width
          spacing: Style.spacing.panelGap

          // The plugin's name, and underneath it how much is free and which
          // stores that came from.
          Item {
            id: hero
            readonly property color tint: root.hasGames
              ? root.foreground
              : (root.bucket("steam").error || root.bucket("epic").error
                  || root.bucket("gog").error ? root.urgent : root.dim)
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
            width: parent.width
            foreground: root.foreground
          }
        }

        // --- One row: a store header, or a game --------------------------
        delegate: Item {
          id: row
          required property var modelData
          required property int index
          width: panelList.width

          readonly property bool isHeader: modelData.kind === "header"

          implicitHeight: isHeader
            ? Style.space(30) + (modelData && modelData.empty ? emptyNote.implicitHeight : 0)
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

            Text {
              id: headerMark
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: Model.STORE_GLYPHS[row.modelData.store] || ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              id: headerLabel
              anchors.left: headerMark.right
              anchors.leftMargin: Style.spacing.xs
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

            // Clickable bell: mute or unmute this store's notifications.
            // Hidden while the store is off, since there is nothing to mute.
            //
            // The glyph alone is a few pixels wide, which is not a target
            // anyone can hit reliably, so it sits in a box the height of the
            // row and the width of the switch beside it. The hover fill is the
            // same treatment a game row gets, so the two read as one kind of
            // control.
            Item {
              id: headerBell
              visible: row.modelData.enabled !== false
              anchors.right: headerSwitch.left
              anchors.rightMargin: Style.spacing.xs
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(30)
              height: Style.space(26)

              Rectangle {
                id: bellHit
                anchors.fill: parent
                radius: Style.cornerRadius
                color: bellMouse.containsMouse
                  ? Style.hoverFillFor(root.foreground, Commons.Color.accent)
                  : "transparent"
              }

              Text {
                anchors.centerIn: parent
                text: root.notifyOn[row.modelData.store]
                  ? "\u{F0F3}" : "\u{F1F6}"
                color: root.notifyOn[row.modelData.store]
                  ? root.dim : Qt.darker(root.dim, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                opacity: root.notifyOn[row.modelData.store] ? 1 : 0.6
              }

              MouseArea {
                id: bellMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleBell(row.modelData.store)
              }
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
            }
          }

          // Why an enabled store has nothing to show.
          Text {
            id: emptyNote
            anchors.top: parent.top
            anchors.topMargin: Style.space(30)
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.sm
            width: parent.width - Style.spacing.sm * 2
            visible: row.isHeader && row.modelData.empty
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: row.modelData.stateLabel || ""
            color: row.modelData.failed ? root.urgent : root.dim
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
            visible: !row.isHeader
            radius: Style.cornerRadius
            color: root.cursorActive && root.selectedIndex === row.index
              ? (root.bar ? Style.selectedFillFor(root.bar.foreground, Commons.Color.accent)
                          : "transparent")
              : (gameMouse.containsMouse
                ? (root.bar ? Style.hoverFillFor(root.bar.foreground, Commons.Color.accent)
                            : "transparent")
                : "transparent")

            Text {
              id: gameTitle
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              // Indented under the store name so the two levels read apart.
              anchors.leftMargin: Style.space(22)
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
              // The pointer picks the store the keyboard acts on, so e and n do
              // not depend on where the keyboard cursor happens to be.
              onEntered: root.targetStore = row.modelData.store
              onClicked: root.openGame(row.modelData)
            }
          }
        }

        // --- Below the list ---------------------------------------------
        footer: Column {
          width: panelList.width
          spacing: Style.spacing.panelGap

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

          // A spacer, so a store's last line — an empty-store note such as "No
          // giveaway running" — does not sit against the rule.
          Item {
            width: parent.width
            height: Style.space(8)
          }

          // A rule between the list and the controls, so the buttons are not
          // read as part of a store's rows.
          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          Button {
            width: parent.width
            text: "Refresh now"
            iconText: "\u{F021}"
            bordered: true
            foreground: root.foreground
            accent: Commons.Color.accent
            fontFamily: root.fontFamily
            onClicked: root.refresh()
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            visible: root.showShortcuts
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            text: "r refresh · e enable/disable store · n mute/unmute notifications · j/k scroll"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // The very last row: the freshness centred, help in the far corner.
          //
          // The text is centred with anchors rather than by filling the row and
          // centring within it, so the help button on the right cannot shift it.
          // Its width is capped at whatever is left over, which keeps a long
          // freshness string from running under the button.
          Item {
            width: parent.width
            implicitHeight: Math.max(bottomText.implicitHeight,
                                     helpButton.implicitHeight)

            Text {
              id: bottomText
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth,
                              parent.width - helpButton.width - Style.space(10))
              textFormat: Text.PlainText
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: root.freshness
              color: root.stale ? root.dim : Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Button {
              id: helpButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "?"
              bordered: true
              foreground: root.foreground
              accent: Commons.Color.accent
              fontFamily: root.fontFamily
              onClicked: root.showShortcuts = !root.showShortcuts
            }
          }
        }
      }
    }
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    targetStore = ""
    showShortcuts = false
    nowMs = Date.now()
    // Opening the panel refreshes when the data is missing or stale, which is
    // what makes a long refresh interval safe to live with.
    if (lastSuccessAt === 0 || stale) refresh()
    acknowledgeCurrent()
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
