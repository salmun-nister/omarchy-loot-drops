pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
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

  // curl is told to give up at 20s; the watchdog fires a little later so a
  // child that ignores its own deadline is still ended rather than left to
  // sit inside the long-lived shell process. fetchDeadlineMs is what the fetch
  // is allowed to take; fetchWatchdogMs is when we stop believing it returns.
  readonly property int fetchDeadlineMs: 20000
  readonly property int fetchWatchdogMs: 25000

  function pluginFile(relative) {
    var url = String(Qt.resolvedUrl(relative))
    if (url.indexOf("file://") === 0) url = url.slice(7)
    return decodeURIComponent(url)
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
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

  readonly property bool stale: lastSuccessAt > 0
    && nowMs - lastSuccessAt >= Model.STALE_AFTER_MS
  readonly property string freshness: Model.freshnessLabel(
    lastSuccessAt, nowMs, anyBusy)
  readonly property var activeStores: Model.activeStores(storesOn)
  readonly property var visibleGames: visibleGameList()
  readonly property bool hasGames: visibleGames.length > 0

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
  function visibleGameList() {
    var list = []
    for (var i = 0; i < Model.STORES.length; i++) {
      var store = Model.STORES[i]
      if (!storesOn[store]) continue
      var games = bucket(store).games
      for (var j = 0; j < games.length; j++) {
        list.push({ store: store, game: games[j] })
      }
    }
    return list
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
    armWatchdog(store)
    updateBusy()
  }

  // One watchdog per store, armed when a fetch starts. A fetch that overruns is
  // killed and recorded as unreachable, so a wedged child cannot leave a store
  // spinning forever or delay the next refresh.
  //
  // The kill goes through the helper rather than Process.kill(), because that
  // only signals the direct child: a child ignoring SIGTERM survives as an
  // orphan still holding the pipe. Signalling the group reaches all of it.
  function armWatchdog(store) {
    var timer = watchdogs[store]
    timer.interval = fetchWatchdogMs
    timer.storeName = store
    timer.restart()
  }

  function onWatchdogFired(store) {
    var proc = fetchProcs[store]
    if (!proc.running) return
    var pgid = proc.processId
    proc.running = false
    if (pgid > 0) {
      killProc.command = [root.python, root.cappedRun, "--kill-group", String(pgid)]
      killProc.running = true
    }
    fail(store, "Timed out waiting for " + storeLabel(store))
  }

  function storeLabel(store) {
    return Model.STORE_LABELS[store] || store
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
    watchdogs[store].stop()
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
    watchdogs[store].stop()
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
      setCursor(selectedIndex)
      return
    }
    for (var i = 0; i < visibleGames.length; i++) {
      var row = visibleGames[i]
      if (row.store + ":" + row.game.id === key) {
        setCursor(i)
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

  function setCursor(index) {
    selectedIndex = Math.max(0, Math.min(Math.max(0, visibleGames.length - 1), index))
  }

  function selectedGame() {
    return selectedIndex >= 0 && selectedIndex < visibleGames.length
      ? visibleGames[selectedIndex] : null
  }

  function openGame(row) {
    if (!row) return
    var store = row.store
    // safeUrl refuses anything off the store's own host, and the search page
    // is the fallback, so a row always opens somewhere legitimate.
    var url = Model.safeUrl(store, row.game.url) || Model.searchUrl(store)
    Quickshell.execDetached(["omarchy-launch-browser", url])
    close()
  }

  function openStore(store) {
    var url = Model.searchUrl(store || activeStores[0])
    if (url) Quickshell.execDetached(["omarchy-launch-browser", url])
  }

  function quit() {
    root.close()
    if (Quickshell.env("LOOT_LIGHTNING_HARNESS") === "1") {
      Qt.quit()
      return
    }
    Quickshell.execDetached(["omarchy", "plugin", "disable", root.moduleName])
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

  // Ends a fetch's whole process group when the watchdog fires. Deliberately
  // short-lived and never awaited: the store is already recorded as timed out.
  Process {
    id: killProc
    running: false
  }

  readonly property var fetchProcs: ({
    "steam": steamProc,
    "epic": epicProc,
    "gog": gogProc
  })

  // --- Timers ------------------------------------------------------------

  // One watchdog per store. Each is idle until a fetch arms it, so the three
  // do not interfere and a store that is switched off never fires one.
  Timer {
    id: steamWatchdog
    property string storeName: "steam"
    interval: root.fetchWatchdogMs
    repeat: false
    onTriggered: root.onWatchdogFired(storeName)
  }

  Timer {
    id: epicWatchdog
    property string storeName: "epic"
    interval: root.fetchWatchdogMs
    repeat: false
    onTriggered: root.onWatchdogFired(storeName)
  }

  Timer {
    id: gogWatchdog
    property string storeName: "gog"
    interval: root.fetchWatchdogMs
    repeat: false
    onTriggered: root.onWatchdogFired(storeName)
  }

  readonly property var watchdogs: ({
    "steam": steamWatchdog,
    "epic": epicWatchdog,
    "gog": gogWatchdog
  })

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
    tooltipText: root.hasGames
      ? Model.statusTitle(root.buckets, root.storesOn, root.anyBusy) + "\n" + root.freshness
      : Model.statusTitle(root.buckets, root.storesOn, root.anyBusy) + "\n" + root.freshness

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else if (buttonCode === Qt.RightButton) root.openStore()
      else root.toggle()
    }
  }

  // --- Panel -------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight,
                                             Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) {
          root.cursorActive = true
          return
        }
        if (dy !== 0) root.setCursor(root.selectedIndex + dy)
      }

      onActivateRequested: root.openGame(root.selectedGame())
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        var key = text.toLowerCase()
        if (key === "r") root.refresh()
        else if (key === "q") root.quit()
        else if (key === "1") root.openStore("steam")
        else if (key === "2") root.openStore("epic")
        else if (key === "3") root.openStore("gog")
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height
          ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.spacing.panelGap

          // Hero: what is free, or why nothing is.
          Item {
            id: hero
            readonly property color tint: root.hasGames
              ? root.foreground
              : (root.bucket("steam").error || root.bucket("epic").error
                  || root.bucket("gog").error ? root.urgent : root.dim)
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight,
                                     heroLabels.implicitHeight)

            Text {
              id: heroIcon
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: Model.BAR_ICON
              color: hero.tint
              font.family: "JetBrainsMono Nerd Font"
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
                text: Model.statusTitle(root.buckets, root.storesOn, root.anyBusy)
                color: hero.tint
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              // Wraps rather than elides: the empty state is a full sentence.
              Text {
                width: parent.width
                textFormat: Text.PlainText
                visible: text !== ""
                text: Model.statusDetail(root.buckets, root.storesOn,
                                         root.anyBusy, root.errorsByStore()).toUpperCase()
                color: Qt.darker(hero.tint, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                wrapMode: Text.WordWrap
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.freshness
            color: root.stale ? root.dim : Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          // One section per enabled store: its state on the right, its games
          // below, and a crossed-out bell when the store is muted.
          Repeater {
            id: storeRepeater
            model: root.activeStores

            Column {
              id: storeSection
              required property string modelData
              readonly property var storeBucket: root.bucket(modelData)
              width: panelColumn.width
              spacing: Style.spacing.xs

              Item {
                width: parent.width
                implicitHeight: Math.max(storeLabel.implicitHeight,
                                         storeBell.implicitHeight)

                Text {
                  id: storeLabel
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.spacing.sm
                  width: parent.width - storeBell.width - Style.spacing.sm * 2
                  textFormat: Text.PlainText
                  // Titles from the network are plain text, never markup.
                  text: Model.STORE_LABELS[storeSection.modelData] || ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.0
                  elide: Text.ElideRight
                }

                Text {
                  id: storeBell
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.rightMargin: Style.spacing.sm
                  // A muted store shows a crossed-out bell rather than
                  // disappearing, so muting is visibly different from off.
                  text: root.notifyOn[storeSection.modelData]
                    ? "\u{F0F3}" : "\u{F1F6}"
                  color: root.notifyOn[storeSection.modelData]
                    ? root.dim : Qt.darker(root.dim, 1.4)
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: Style.font.caption
                  opacity: root.notifyOn[storeSection.modelData] ? 1 : 0.6
                }
              }

              Repeater {
                model: storeSection.storeBucket.games

                Rectangle {
                  id: gameRow
                  // A game is an object, not a string; declaring it as string
                  // leaves the title undefined.
                  required property var modelData
                  width: storeSection.width
                  implicitHeight: Math.max(Style.space(28),
                                           gameTitle.implicitHeight + Style.spacing.sm)
                  radius: Style.cornerRadius
                  color: root.cursorActive
                    && root.selectedIndex === root.rowIndexOf(storeSection.modelData, gameRow)
                    ? (root.bar ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                                : "transparent")
                    : (rowMouse.containsMouse
                      ? (root.bar ? Style.hoverFillFor(root.bar.foreground, Color.accent)
                                  : "transparent")
                      : "transparent")

                  Text {
                    id: gameTitle
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.spacing.sm
                    anchors.rightMargin: Style.spacing.sm
                    textFormat: Text.PlainText
                    text: gameRow.modelData.title
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }

                  MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openGame({
                      store: storeSection.modelData,
                      game: gameRow.modelData
                    })
                  }
                }
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                visible: storeSection.storeBucket.games.length === 0
                wrapMode: Text.WordWrap
                text: Model.storeStateLabel(storeSection.modelData,
                                            storeSection.storeBucket,
                                            root.errorsByStore())
                color: storeSection.storeBucket.error ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            visible: root.activeStores.length === 0
            wrapMode: Text.WordWrap
            text: "Every store is switched off. Turn one on in the Omarchy settings to start watching."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            width: parent.width
            text: "Refresh now"
            iconText: "\u{F021}"
            bordered: true
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: root.refresh()
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: "Left-click the icon for this list. Middle-click refreshes. Right-click opens the first enabled store. Keys: r refresh, 1/2/3 open Steam/Epic/GOG, q quit."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Item {
            width: parent.width
            implicitHeight: quitButton.implicitHeight

            Button {
              id: quitButton
              anchors.right: parent.right
              text: "Quit"
              bordered: true
              foreground: root.foreground
              accent: Color.accent
              fontFamily: root.fontFamily
              onClicked: root.quit()
            }
          }
        }
      }
    }
  }

  // Maps a (store, game id) pair to its index in the flat visible list, so the
  // cursor highlight survives the grouped layout.
  function rowIndexOf(store, id) {
    for (var i = 0; i < visibleGames.length; i++) {
      if (visibleGames[i].store === store && visibleGames[i].game.id === id) return i
    }
    return -1
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
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
