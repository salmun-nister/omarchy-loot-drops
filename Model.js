.pragma library

// Parsing, allowlisting, seen-id transitions and notification copy for every
// store. Every value here comes from a network response that is
// attacker-controlled if the store is wrong or the connection is intercepted,
// so nothing leaves this file without passing the host allowlist or the title
// scrub. The widget owns transport, persistence and rendering.

var STORES = ["steam", "epic", "gog", "amazon"]

var STORE_LABELS = {
  "steam": "Steam",
  "epic": "Epic Games",
  "gog": "GOG",
  "amazon": "Amazon Luna"
}

// Store marks beside each header. Steam, GOG and Amazon are the real logos,
// taken from the Material Design and Font Awesome sets in Nerd Fonts 3.5.1
// (U+F04D3, U+F0BA1 and U+F270; GOG's codepoint moves between releases, so the
// version matters). Nerd Fonts ships no Epic mark at all, so Epic borrows its
// initial rather than wearing a storefront icon that is not its own.
// The IpcHandler target the bar widget registers and the notification's click
// action addresses. Both sides read it from here so they cannot drift apart:
// a notification that calls a target the widget no longer publishes would
// silently do nothing.
var IPC_TARGET = "salmun-nister.loot-drops"

var STORE_GLYPHS = {
  "steam": "\u{F04D3}",
  "epic": "\u{F04DC}",
  "gog": "\u{F0BA1}",
  "amazon": "\u{F270}"
}

// Short forms, used only by the panel's subtitle. That line is uppercased and
// letter-spaced, so "Epic Games" makes it long enough to wrap; the headers and
// the notification headline keep the full names.
var STORE_SHORT = {
  "steam": "Steam",
  "epic": "Epic",
  "gog": "GOG",
  "amazon": "Amazon"
}

// The canonical host each store's links may point at. A title and a URL both
// reach sinks that launch a browser, so the URL is rebuilt from the parsed id
// rather than trusted from the response wherever the store allows it.
var HOSTS = {
  "steam": "store.steampowered.com",
  "epic": "store.epicgames.com",
  "gog": "www.gog.com",
  "amazon": "luna.amazon.com"
}

var SEARCH_URLS = {
  "steam": "https://store.steampowered.com/search/?maxprice=free&specials=1",
  "epic": "https://store.epicgames.com/free-games",
  "gog": "https://www.gog.com/giveaways",
  "amazon": "https://luna.amazon.com/claims/home"
}

// U+F0726, the Material Design treasure chest in the Nerd Font. Deliberately
// not U+26A1: that codepoint has Emoji_Presentation=Yes, so Qt hands it to
// the colour emoji font and it paints its own colour in every theme,
// ignoring the palette. A private-use codepoint has no emoji presentation,
// so this one renders monochrome and takes the colour it is given, like
// every bar icon.
var BAR_ICON = "󰜦"
// U+EDE8, the Font Awesome coins glyph (a stack of coins) in Nerd Fonts 3.5.1.
// Private use like BAR_ICON, so it paints monochrome and takes the theme colour.
// Marks a game the panel has not acknowledged yet. Note the codepoint moved
// between Nerd Fonts releases: F51E, the Font Awesome coins position in 3.0,
// is oct-stack in 3.5.1, so the version matters here as it does for the GOG mark.
var NEW_GAME_GLYPH = "\u{EDE8}"
// U+F253, the Font Awesome "hourglass-end" (sand almost run out) in Nerd Fonts
// 3.5.1. Private use like the other marks, so it paints monochrome and takes the
// colour it is given. It stands in for the coin when a giveaway is ending soon.
var HOURGLASS_GLYPH = "\u{F253}"
// How close to a giveaway's end counts as "ending soon". A date already past
// still counts (see endingSoon), so the mark survives until a refresh drops the
// game or moves its end date back out of the window.
var ENDING_SOON_MS = 24 * 60 * 60 * 1000
var MAX_BYTES = 4000000
var MAX_GAMES = 40
var MAX_TITLE = 120
var MAX_BLOCK = 20000
var MAX_ID = 64
var MAX_SEEN_BYTES = 32768
var MAX_SEEN_IDS = 120
var USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
// The refresh interval bounds, shared with the manifest schema so the settings
// slider and the normaliser cannot drift apart.
var REFRESH_MIN = 30
var REFRESH_DEFAULT = 90
var REFRESH_MAX = 720

// Stale is derived from the interval rather than fixed. A constant drifts out of
// proportion the moment the interval changes — at a 90-minute default a fixed
// four hours is barely more than one missed poll, and at 720 it would be under
// one. 1.5x keeps "stale" meaning "we may have missed something" at any rate.
var STALE_MULTIPLIER = 1.5

// Steam ids are digits. Epic, GOG and Amazon use opaque ids, so the safe
// character set is shared and the host allowlist does the real work. Amazon
// claim ids are 50 characters ("amzn1.pg.item." plus a UUID), hence the cap.
var ID_RE = /^[A-Za-z0-9._-]{1,64}$/
var STEAM_ID_RE = /^\d{1,10}$/

var MAX_URL = 300
var URL_RE = /^https:\/\/[A-Za-z0-9.-]{1,253}(\/[!-~]*)?$/

// ---------------------------------------------------------------------------
// Shared scrubbers
// ---------------------------------------------------------------------------

// Every display sink reads through here, so the order matters. Whole tags are
// removed first, entities are decoded second (decoding turns "&lt;b&gt;" back
// into a live tag), and only then are stray angle brackets and control
// characters stripped, because the notification server advertises body markup
// and body hyperlinks.
function scrubTitle(value) {
  return decodeEntities(
      String(value == null ? "" : value).replace(/<[^>]*>/g, ""))
    .replace(/[<>]/g, "")
    .replace(/[\u0000-\u001f\u007f-\u009f]/g, " ")
    .replace(/[\u202a-\u202e\u2066-\u2069]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, MAX_TITLE)
}

function scrubId(value) {
  var id = String(value == null ? "" : value).trim()
  return ID_RE.test(id) ? id : ""
}

function decodeEntities(value) {
  return String(value == null ? "" : value)
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&quot;/gi, "\"")
    .replace(/&#39;/gi, "'")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&#x([0-9a-f]{1,6});/gi, function(_, hex) {
      return safeFromCodePoint(parseInt(hex, 16))
    })
    .replace(/&#(\d{1,7});/g, function(_, dec) {
      return safeFromCodePoint(parseInt(dec, 10))
    })
}

function safeFromCodePoint(code) {
  if (!isFinite(code) || code < 32 || code > 0x10ffff) return ""
  // Surrogates would let a title encode a bidirectional or format control
  // through a numeric entity, so they are dropped like the literal forms.
  if (code >= 0xd800 && code <= 0xdfff) return ""
  if (code >= 0x202a && code <= 0x202e) return ""
  if (code >= 0x2066 && code <= 0x2069) return ""
  return String.fromCodePoint(code)
}

// Returns "" for anything that is not an https URL on the store's own host, so
// callers fall back to the store's search page rather than launching what the
// network sent. The path is re-checked character by character because a URL
// carrying credentials or a second origin is the thing this must not open.
function safeUrl(store, value) {
  var url = String(value == null ? "" : value).trim().split("#")[0]
  if (!url || url.length > MAX_URL || !URL_RE.test(url)) return ""
  var host = HOSTS[store]
  if (!host) return ""
  var authority = url.slice("https://".length).split("/")[0]
  if (authority.toLowerCase() !== host) return ""
  return url
}

// The page to open when a row's own link is unusable, or when right-clicking
// the bar mark with no particular store in mind. Falls back to the first
// enabled store rather than to nothing, so it always returns a real URL for a
// store this plugin knows about.
function searchUrl(store, firstEnabled) {
  var target = HOSTS[store] ? store : (HOSTS[firstEnabled] ? firstEnabled : "")
  return target ? SEARCH_URLS[target] : ""
}

function enabled(settings) {
  return {
    "steam": setting(settings, "steamEnabled", true),
    "epic": setting(settings, "epicEnabled", true),
    "gog": setting(settings, "gogEnabled", true),
    // Off by default: this store renders a page in headless Chromium, so it
    // costs more than a single request and is only worth it if the user wants
    // Amazon's giveaways.
    "amazon": setting(settings, "amazonEnabled", false)
  }
}

function notifyFor(settings) {
  return {
    "steam": setting(settings, "steamNotify", true),
    "epic": setting(settings, "epicNotify", true),
    "gog": setting(settings, "gogNotify", true),
    "amazon": setting(settings, "amazonNotify", true)
  }
}

function setting(settings, key, fallback) {
  if (!settings || typeof settings !== "object") return fallback
  var value = settings[key]
  return value === undefined || value === null ? fallback : value
}

function normalizeCountry(value) {
  var cc = String(value == null ? "" : value).trim().toUpperCase()
  return /^[A-Z]{2}$/.test(cc) ? cc : ""
}

function normalizeRefreshMinutes(value) {
  var minutes = Math.round(Number(value))
  if (!isFinite(minutes)) minutes = REFRESH_DEFAULT
  return Math.max(REFRESH_MIN, Math.min(REFRESH_MAX, minutes))
}

// When data counts as stale, given the refresh interval it is on.
function staleAfterMs(refreshMinutes) {
  var minutes = normalizeRefreshMinutes(refreshMinutes)
  return Math.round(minutes * STALE_MULTIPLIER * 60 * 1000)
}

// Whether a giveaway's end is within ENDING_SOON_MS, or already past. A past end
// date deliberately still counts: the row is still listed, and the date may have
// been extended or the store simply not re-fetched yet. The mark therefore needs
// no memory of its own; it clears when a refresh drops the game or moves its end
// date more than the window away. An absent or malformed date yields no mark, so
// those rows read exactly as they did before.
function endingSoon(endsAt, nowMs) {
  var end = parseTime(endsAt)
  return end > 0 && end - Number(nowMs) <= ENDING_SOON_MS
}

// ---------------------------------------------------------------------------
// Store parsers
// ---------------------------------------------------------------------------

function parseStore(store, raw) {
  var text = String(raw == null ? "" : raw).trim()
  if (!text || text.length > MAX_BYTES) return { ok: false, games: [], error: "invalid-response" }
  if (store === "steam") return parseSteam(text)
  if (store === "epic") return parseEpic(text)
  if (store === "gog") return parseGog(text)
  if (store === "amazon") return parseAmazon(text)
  return { ok: false, games: [], error: "invalid-response" }
}

// Steam's infinite-scroll endpoint answers with JSON carrying a results_html
// blob of <a class="search_result_row"> elements. Anything else means we did
// not reach Steam.
function parseSteam(text) {
  var payload
  try {
    payload = JSON.parse(text)
  } catch (e) {
    return { ok: false, games: [], error: "invalid-response" }
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return { ok: false, games: [], error: "invalid-response" }
  }
  // The endpoint always carries a results_html string. Its absence means we
  // did not reach Steam, and reporting that as "no free games" would silently
  // swallow an outage.
  if (typeof payload.results_html !== "string") {
    return { ok: false, games: [], error: "invalid-response" }
  }
  var rows = parseSteamRows(payload.results_html)
  if (rows === null) return { ok: false, games: [], error: "invalid-response" }
  return { ok: true, games: rows }
}

function parseSteamRows(html) {
  var games = []
  var seen = {}
  var text = String(html || "")
  var index = 0

  while (games.length < MAX_GAMES) {
    var start = text.indexOf("<a", index)
    if (start < 0) break
    var tagEnd = text.indexOf(">", start)
    if (tagEnd < 0) break
    var openTag = text.slice(start, tagEnd + 1)
    if (openTag.indexOf("search_result_row") < 0) {
      index = start + 2
      continue
    }
    var close = text.indexOf("</a>", tagEnd)
    if (close < 0) break
    var game = parseSteamRow(text.slice(start, close))
    index = close + 4
    if (!game || seen[game.id]) continue
    seen[game.id] = true
    games.push(game)
  }

  return games
}

function parseSteamRow(block) {
  var id = firstId(matchAttr(block, "data-ds-appid"))
    || firstId(matchAttr(block, "data-ds-bundleid"))
    || firstId(matchAttr(block, "data-ds-packageid"))
  if (!id) return null

  // The href is dropped rather than validated: the canonical store URL is
  // rebuilt from a digits-only id, so there is nothing to allowlist.
  return {
    store: "steam",
    id: id,
    title: matchSteamTitle(block) || ("Steam " + id),
    url: "https://" + HOSTS.steam + "/app/" + id + "/"
  }
}

// Steam's row attributes are digits only, so a short anchored scan is enough.
// The value is bounded before it is returned because it is concatenated into a
// URL further down.
function firstId(value) {
  var match = String(value == null ? "" : value).match(/^\s*(\d{1,10})\s*$/)
  return match ? match[1] : ""
}

// Reads one quoted attribute out of a tag fragment. The name is escaped because
// it comes from the caller, and the captured value is length-bounded so a
// hostile page cannot make this return a megabyte.
function matchAttr(text, name) {
  var attribute = String(name == null ? "" : name).replace(/[^\w-]/g, "")
  if (!attribute) return ""
  var pattern = new RegExp(
    "(?:^|\\s)" + attribute + "\\s*=\\s*(?:\"([^\"]{0,512})\"|'([^']{0,512})')", "i")
  var match = String(text == null ? "" : text).match(pattern)
  if (!match) return ""
  return match[1] !== undefined ? match[1] : match[2]
}

function matchSteamTitle(text) {
  var block = String(text || "").slice(0, MAX_BLOCK)
  var match = block.match(/<span[^>]*class="[^"]*\btitle\b[^"]*"[^>]*>([\s\S]*?)<\/span>/i)
  if (!match) return ""
  return scrubTitle(decodeEntities(match[1].replace(/<[^>]+>/g, "")))
}

// Epic keeps a promotion array that includes finished offers, so a game counts
// as free only when a zero-discount window is still open at nowMs.
function parseEpic(text) {
  var payload
  try {
    payload = JSON.parse(text)
  } catch (e) {
    return { ok: false, games: [], error: "invalid-response" }
  }
  var elements = payload && payload.data && payload.data.Catalog
    && payload.data.Catalog.searchStore
    && payload.data.Catalog.searchStore.elements
  if (!Array.isArray(elements)) {
    return { ok: false, games: [], error: "invalid-response" }
  }

  var now = Date.now()
  var games = []
  var seen = {}
  for (var i = 0; i < elements.length && games.length < MAX_GAMES; i++) {
    var game = epicGame(elements[i], now)
    if (!game || seen[game.id]) continue
    seen[game.id] = true
    games.push(game)
  }
  return { ok: true, games: games }
}

function epicGame(element, now) {
  if (!element || typeof element !== "object") return null
  var promotions = element.promotions
  if (!promotions || typeof promotions !== "object") return null

  var free = null
  var current = promotions.promotionalOffers
  if (Array.isArray(current)) {
    for (var i = 0; i < current.length && !free; i++) {
      free = liveFreeOffer(current[i], now)
    }
  }
  if (!free) return null

  var id = scrubId(element.id) || scrubId(epicSlug(element))
  if (!id) return null

  // Epic's own `url` field comes back empty, so the link is built from the
  // catalog mapping and re-checked against the Epic host like every other URL.
  var slug = epicSlug(element)
  var path = element.offerType === "BUNDLE" ? "bundles" : "p"
  return {
    store: "epic",
    id: id,
    title: scrubTitle(element.title),
    url: safeUrl("epic", "https://" + HOSTS.epic + "/" + path + "/" + slug),
    endsAt: free
  }
}

function epicSlug(element) {
  var mappings = element.catalogNs && element.catalogNs.mappings
  if (Array.isArray(mappings) && mappings.length > 0) {
    var page = scrubId(mappings[0] && mappings[0].pageSlug)
    if (page) return page
  }
  return scrubId(element.urlSlug) || scrubId(element.productSlug)
}

// Returns the end timestamp of a zero-discount window that is still running,
// or "" when the window is absent, already finished, or a paid promotion.
function liveFreeOffer(group, now) {
  if (!group || typeof group !== "object") return ""
  var offers = group.promotionalOffers
  if (!Array.isArray(offers)) return ""
  for (var i = 0; i < offers.length; i++) {
    var offer = offers[i]
    if (!offer || typeof offer !== "object") continue
    var setting_ = offer.discountSetting
    if (!setting_ || setting_.discountPercentage !== 0) continue
    var end = parseTime(offer.endDate)
    if (!end) continue
    var start = parseTime(offer.startDate)
    if (start && start > now) continue
    if (end <= now) continue
    return offer.endDate
  }
  return ""
}

function parseTime(value) {
  var text = String(value == null ? "" : value).trim()
  if (!text || text.length > 40) return 0
  var ms = Date.parse(text)
  return isFinite(ms) ? ms : 0
}

// GOG answers 404 with no giveaway running. That is a healthy empty store, so
// it is reported as ok with no games rather than as an error.
function parseGog(text) {
  var payload
  try {
    payload = JSON.parse(text)
  } catch (e) {
    return { ok: false, games: [], error: "invalid-response" }
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return { ok: false, games: [], error: "invalid-response" }
  }

  var raw = scrubId(payload.id) || scrubId(payload.gameId)
  // A payload whose id will not survive scrubId is not a giveaway we can
  // identify or link to, so it is malformed rather than merely empty.
  if (!raw) return { ok: false, games: [], error: "invalid-response" }
  var game = gogGame(payload, raw)
  return { ok: true, games: game ? [game] : [] }
}

function gogGame(payload, id) {
  var title = scrubTitle(payload.title)
  if (!title) return null

  // scrubId already refuses whitespace, punctuation and path traversal, so the
  // slug that reaches the URL builder cannot carry them either. A game with no
  // usable slug still lists, with an empty url so the panel falls back to the
  // store search; this assignment used to be undeclared, so that path threw a
  // ReferenceError instead of returning the row.
  var slug = scrubId(payload.slug)
  var url = slug ? safeUrl("gog", "https://" + HOSTS.gog + "/game/" + slug) : ""
  return {
    store: "gog",
    id: id,
    title: title,
    url: url,
    endsAt: parseTime(payload.endDate) ? String(payload.endDate) : ""
  }
}

// Amazon Luna has no endpoint a script may read: the claims grid exists only
// after the page's own scripts run, and the GraphQL behind it rejects clients
// without a browser's TLS fingerprint. The widget therefore renders the
// signed-out claims page in headless Chromium and this parser reads the
// produced DOM. The pre-script shell contains neither marker below, so a page
// without the grid is a bot block, a sign-in wall or a redesign and must
// surface as an error rather than as an empty store. A grid that yields no
// cards is treated the same way: the container only exists once the app has
// rendered, and Luna always has a current lineup, so an empty parse is a markup
// change rather than a healthy empty store.
function parseAmazon(text) {
  var html = String(text == null ? "" : text)
  if (!html || html.length > MAX_BYTES) {
    return { ok: false, games: [], error: "invalid-response" }
  }
  var gridAt = html.indexOf('data-a-target="offer-list-FGWP_FULL"')
  if (gridAt < 0) return { ok: false, games: [], error: "invalid-response" }

  // Every card is wrapped in a learn-more anchor carrying the claim path, so
  // cards are found by that marker rather than by the call-to-action text,
  // which varies ("Claim game", "Get game"). Scoping to the grid skips the
  // featured carousel above it, whose cards repeat the same games.
  var marker = 'data-a-target="learn-more-card"'
  var games = []
  var seen = {}
  var index = gridAt
  while (games.length < MAX_GAMES) {
    var at = html.indexOf(marker, index)
    if (at < 0) break
    var start = html.lastIndexOf("<a", at)
    if (start < 0) start = at
    var next = html.indexOf(marker, at + marker.length)
    var card = html.slice(start, next < 0 ? html.length : next)
    index = next < 0 ? html.length : next
    var game = amazonCard(card)
    if (!game || seen[game.id]) continue
    seen[game.id] = true
    games.push(game)
  }
  if (games.length === 0) return { ok: false, games: [], error: "invalid-response" }
  return { ok: true, games: games }
}

// One card's wrapper anchor carries the title and a path shaped
// /claims/<slug>/dp/<item id>. Both segments are parsed and the link is
// rebuilt from them, so the network's host and query string are never used.
function amazonCard(card) {
  var path = String(matchAttr(card, "href") || "").split("#")[0].split("?")[0]
  var parts = path.split("/")
  if (parts.length !== 5 || parts[0] !== "" || parts[1] !== "claims" || parts[3] !== "dp") {
    return null
  }
  var slug = scrubId(parts[2])
  var id = scrubId(parts[4])
  if (!slug || !id) return null

  var heading = String(card).match(/<h3[^>]*\btitle="([^"]{1,512})"/i)
  var title = heading ? scrubTitle(heading[1]) : ""
  // The heading is the visible title; the wrapper's aria-label repeats it, so
  // it is only a fallback for a variant that omits the heading.
  if (!title) title = scrubTitle(matchAttr(card, "aria-label"))
  if (!title) return null

  return {
    store: "amazon",
    id: id,
    title: title,
    url: safeUrl("amazon", "https://" + HOSTS.amazon + "/claims/" + slug + "/dp/" + id)
  }
}

// ---------------------------------------------------------------------------
// Seen state
// ---------------------------------------------------------------------------

function emptySeen() {
  var stores = {}
  for (var i = 0; i < STORES.length; i++) {
    stores[STORES[i]] = { ids: [], acknowledged: [], primed: false }
  }
  return { primed: false, stores: stores }
}

// The ids of games the user has actually looked at in the panel, per store.
// Distinct from `ids`, which is the notification baseline: a game can have been
// announced already and still not been seen, and it is that which lights the
// bar dot.
function acknowledgedOf(state, store) {
  var bucket = state && state.stores ? state.stores[store] : null
  var list = bucket && Array.isArray(bucket.acknowledged) ? bucket.acknowledged : []
  var out = []
  for (var i = 0; i < list.length && out.length < MAX_SEEN_IDS; i++) {
    var id = scrubId(list[i])
    if (id) out.push(id)
  }
  return out
}

// Mark one game as looked at, so its per-row marker clears and the bar dot can
// go out once nothing is left unseen. Called per game when it is launched, when
// its marker is clicked, or with the h key; siblings and the notification
// baseline are untouched. At the cap the oldest id is dropped rather than
// refusing the new one, or a game could never be acknowledged once the list
// filled.
function acknowledgeGame(state, store, id) {
  var next = { primed: true, stores: copyStores(state && state.stores) }
  if (STORES.indexOf(store) < 0) return next
  var clean = scrubId(id)
  if (!clean) return next
  var acknowledged = acknowledgedOf(state, store)
  if (acknowledged.indexOf(clean) >= 0) return next
  acknowledged.push(clean)
  while (acknowledged.length > MAX_SEEN_IDS) acknowledged.shift()
  var previous = next.stores[store] || { ids: [], acknowledged: [], primed: false }
  next.stores[store] = {
    ids: previous.ids.slice(0, MAX_SEEN_IDS),
    acknowledged: acknowledged,
    primed: previous.primed === true
  }
  return next
}

// The inverse: drop one game from the acknowledged set so its marker and the
// bar dot come back. Used by the s toggle. Forgetting a game that was not
// acknowledged is a no-op.
function forgetGame(state, store, id) {
  var next = { primed: true, stores: copyStores(state && state.stores) }
  if (STORES.indexOf(store) < 0) return next
  var clean = scrubId(id)
  if (!clean) return next
  var acknowledged = acknowledgedOf(state, store)
  var at = acknowledged.indexOf(clean)
  if (at < 0) return next
  acknowledged.splice(at, 1)
  var previous = next.stores[store] || { ids: [], acknowledged: [], primed: false }
  next.stores[store] = {
    ids: previous.ids.slice(0, MAX_SEEN_IDS),
    acknowledged: acknowledged,
    primed: previous.primed === true
  }
  return next
}

// Games on offer right now that the user has not yet looked at. This is what
// the bar dot reports; it is deliberately independent of notifications, so a
// muted store still shows a dot for something you have not seen.
function unseenIds(state, perStore) {
  var out = []
  for (var i = 0; i < STORES.length; i++) {
    var store = STORES[i]
    var current = perStore && perStore[store]
    var games = current && Array.isArray(current.games) ? current.games : []
    if (games.length === 0) continue
    var seen = {}
    var already = acknowledgedOf(state, store)
    for (var a = 0; a < already.length; a++) seen[already[a]] = true
    for (var j = 0; j < games.length; j++) {
      var id = games[j] ? scrubId(games[j].id) : ""
      if (id && !seen[id]) out.push(id)
    }
  }
  return out
}

function hasUnseen(state, perStore) {
  return unseenIds(state, perStore).length > 0
}

// Splits one store's games into the ones the user has not acknowledged and a
// count of the ones they have. Store order is preserved, so with the seen games
// hidden the remaining rows keep the order they arrived in.
function splitSeenGames(games, acknowledgedIds) {
  var acknowledged = {}
  var list = Array.isArray(acknowledgedIds) ? acknowledgedIds : []
  for (var i = 0; i < list.length; i++) {
    var acked = scrubId(list[i])
    if (acked) acknowledged[acked] = true
  }

  var shown = []
  var hidden = 0
  var source = Array.isArray(games) ? games : []
  for (var j = 0; j < source.length; j++) {
    var game = source[j]
    var id = game ? scrubId(game.id) : ""
    if (id && acknowledged[id]) {
      hidden++
      continue
    }
    if (game) shown.push(game)
  }
  return { shown: shown, hidden: hidden }
}

// The summary row's copy when seen games are hidden from the panel.
function hiddenSeenLabel(count) {
  var n = Math.max(0, Math.round(Number(count) || 0))
  return n === 1 ? "1 seen game hidden" : n + " seen games hidden"
}

function parseSeen(raw) {
  var text = String(raw == null ? "" : raw).trim()
  if (!text || text.length > MAX_SEEN_BYTES) return emptySeen()
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return emptySeen()
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) return emptySeen()

  var stores = {}
  for (var i = 0; i < STORES.length; i++) {
    var store = STORES[i]
    var bucket = data.stores && data.stores[store]
    var ids = []
    var seen = {}
    var list = bucket && typeof bucket === "object" && Array.isArray(bucket.ids)
      ? bucket.ids : []
    for (var j = 0; j < list.length && ids.length < MAX_SEEN_IDS; j++) {
      var id = scrubId(list[j])
      if (!id || seen[id]) continue
      seen[id] = true
      ids.push(id)
    }
    var acknowledged = []
    var ackedSeen = {}
    var ackedList = bucket && Array.isArray(bucket.acknowledged)
      ? bucket.acknowledged : []
    for (var a = 0; a < ackedList.length && acknowledged.length < MAX_SEEN_IDS; a++) {
      var acked = scrubId(ackedList[a])
      if (!acked || ackedSeen[acked]) continue
      ackedSeen[acked] = true
      acknowledged.push(acked)
    }
    // A store with recorded ids has necessarily been fetched before, so its
    // primed flag is derived rather than trusted from the file.
    stores[store] = {
      ids: ids,
      acknowledged: acknowledged,
      primed: !!(bucket && bucket.primed === true) || ids.length > 0
    }
  }
  return { primed: data.primed === true, stores: stores }
}

function serializeSeen(state) {
  var stores = {}
  for (var i = 0; i < STORES.length; i++) {
    var store = STORES[i]
    var bucket = state && state.stores ? state.stores[store] : null
    var ids = []
    var source = bucket && typeof bucket === "object" && Array.isArray(bucket.ids)
      ? bucket.ids : []
    for (var j = 0; j < source.length && ids.length < MAX_SEEN_IDS; j++) {
      var id = scrubId(source[j])
      if (id) ids.push(id)
    }
    ids.sort()
    var acknowledged = []
    var ackedSource = bucket && typeof bucket === "object"
      && Array.isArray(bucket.acknowledged) ? bucket.acknowledged : []
    for (var a = 0; a < ackedSource.length && acknowledged.length < MAX_SEEN_IDS; a++) {
      var acked = scrubId(ackedSource[a])
      if (acked) acknowledged.push(acked)
    }
    acknowledged.sort()
    stores[store] = {
      ids: ids,
      acknowledged: acknowledged,
      primed: !!(bucket && bucket.primed === true)
    }
  }
  return JSON.stringify({ primed: !!(state && state.primed), stores: stores })
}

// diffStore compares one store's current games against its recorded baseline
// and returns the next state plus the games worth alerting on.
//
// Three silencing rules, all per store so toggling one never disturbs another:
//   * a store with no baseline records its first snapshot without alerting;
//   * a store that is switched off keeps its baseline, so switching it back on
//     re-records silently instead of announcing everything it missed;
//   * a muted store updates its baseline, so unmuting later does not replay a
//     backlog of games that were already there.
function diffStore(state, store, games, storeEnabled, notifyEnabled) {
  var current = state && typeof state === "object" && state.stores
    ? state : emptySeen()
  var previous = current.stores[store] || { ids: [], acknowledged: [], primed: false }

  var known = {}
  for (var k = 0; k < previous.ids.length; k++) known[previous.ids[k]] = true

  var ids = []
  var list = Array.isArray(games) ? games : []
  for (var i = 0; i < list.length && ids.length < MAX_SEEN_IDS; i++) {
    var id = list[i] ? scrubId(list[i].id) : ""
    if (id) ids.push(id)
  }

  var alerts = []
  if (previous.primed === true && storeEnabled && notifyEnabled) {
    for (var j = 0; j < list.length; j++) {
      var game = list[j]
      if (game && game.id && !known[game.id]) {
        // The store is stamped here rather than trusted from the caller, so a
        // game can never claim to belong to a different store than the one
        // being notified about.
        alerts.push({
          store: store,
          id: game.id,
          title: scrubTitle(game.title),
          url: safeUrl(store, game.url)
        })
      }
    }
  }

  var next = { primed: true, stores: copyStores(current.stores) }
  if (storeEnabled) {
    // The notification baseline moves; the record of what has been looked at
    // does not. Replacing the bucket wholesale would clear the latter.
    next.stores[store] = {
      ids: ids,
      acknowledged: previous.acknowledged.slice(0, MAX_SEEN_IDS),
      primed: true
    }
  } else {
    // Disabled: the baseline is preserved verbatim, and priming is dropped so
    // the next enabled fetch records without alerting.
    next.stores[store] = {
      ids: previous.ids.slice(0, MAX_SEEN_IDS),
      acknowledged: previous.acknowledged.slice(0, MAX_SEEN_IDS),
      primed: false
    }
  }

  return { state: next, alerts: alerts }
}

function copyStores(stores) {
  var out = {}
  for (var i = 0; i < STORES.length; i++) {
    var store = STORES[i]
    var bucket = stores && stores[store]
    out[store] = {
      ids: bucket && Array.isArray(bucket.ids) ? bucket.ids.slice(0, MAX_SEEN_IDS) : [],
      // Carried through every rebuild. Leaving it out here silently cleared the
      // record of what the user had looked at on the next refresh, which lit the
      // bar dot for games they had already seen.
      acknowledged: bucket && Array.isArray(bucket.acknowledged)
        ? bucket.acknowledged.slice(0, MAX_SEEN_IDS) : [],
      primed: !!(bucket && bucket.primed === true)
    }
  }
  return out
}

// ---------------------------------------------------------------------------
// Notification copy
// ---------------------------------------------------------------------------

// The headline sits in omarchy-notification-send's option position, which is
// parsed before the positional is captured, so a title that is exactly a known
// flag would be eaten as one. Leading dashes never survive into that slot.
function notificationArgs(store, alerts) {
  if (!alerts || alerts.length === 0) return null
  var label = STORE_LABELS[store] || "a store"
  var list = alerts.slice(0, 4)
  var names = []
  for (var i = 0; i < list.length; i++) names.push(scrubTitle(list[i].title))
  var extra = alerts.length - names.length
  var body = names.join(", ")
  if (extra > 0) body += " and " + extra + " more"

  var headline
  if (alerts.length === 1) headline = names[0] + " is free on " + label
  else headline = alerts.length + " free games on " + label

  return [
    "omarchy-notification-send",
    "--app-name", "Loot Drops",
    "-g", BAR_ICON,
    "-u", "normal",
    "-t", "12000",
    String(headline).replace(/^-+/, "").trim() || ("Free on " + label),
    body,
    // The click opens the panel rather than the store page. Opening a URL from
    // here went through omarchy-launch-browser, whose trailing focus step picks
    // a window by position in hyprctl's client list rather than by focus order,
    // so the tab landed in whichever window that happened to be first. Opening
    // the panel also acknowledges the games, which is what a click on the toast
    // means anyway. -q keeps a restarting shell from writing to stderr.
    "--exec", "omarchy-shell", "-q", IPC_TARGET, "open"
  ]
}

// ---------------------------------------------------------------------------
// Status copy
// ---------------------------------------------------------------------------

function totalGames(perStore) {
  var total = 0
  for (var i = 0; i < STORES.length; i++) {
    var bucket = perStore && perStore[STORES[i]]
    if (bucket && Array.isArray(bucket.games)) total += bucket.games.length
  }
  return total
}

function activeStores(on) {
  var out = []
  for (var i = 0; i < STORES.length; i++) {
    if (on && on[STORES[i]]) out.push(STORES[i])
  }
  return out
}

function statusTitle(perStore, on, busy) {
  if (activeStores(on).length === 0) return "No stores watched"
  var total = totalGames(perStore)
  if (total === 0) return busy ? "Checking the stores" : "Nothing free right now"
  if (total === 1) return "1 game free to keep"
  return total + " games free to keep"
}

// "Steam, Epic, and GOG" — the stores being watched, named so the panel says
// where the list came from. Short forms, because this is the subtitle.
function storeList(on) {
  var names = []
  for (var i = 0; i < STORES.length; i++) {
    if (on && on[STORES[i]]) names.push(STORE_SHORT[STORES[i]] || STORES[i])
  }
  if (names.length === 0) return ""
  if (names.length === 1) return names[0]
  return names.slice(0, names.length - 1).join(", ") + ", and " + names[names.length - 1]
}

// The panel's headline. The plugin's name is the title and the count moves to
// the subtitle, which names the stores being watched.
function heroTitle() {
  return "Loot Drops"
}

function heroDetail(perStore, on) {
  var watched = storeList(on)
  if (watched === "") return "Turn a store on to start watching"
  var total = totalGames(perStore)
  var noun = total === 1 ? "FREE GAME" : "FREE GAMES"
  return total + " " + noun + " FROM " + watched
}


// The only thing a store row still says: that its fetch failed. The empty and
// "N free games" states are gone, because the panel's subtitle already counts
// the games and an empty store needs no explanation.
function storeErrorLabel(store, errors) {
  var error = errors && errors[store]
  return error && error.message ? error.message : ""
}


function freshnessLabel(lastSuccessAt, nowMs, busy, staleAfter) {
  if (!lastSuccessAt) return busy ? "Checking the stores" : "Not checked yet"
  var age = Math.max(0, Number(nowMs) - lastSuccessAt)
  if (!isFinite(age)) age = 0
  if (age >= staleAfter) return "Stale · " + ageLabel(age)
  if (age < 15000) return "Updated just now"
  return "Updated " + ageLabel(age) + " ago"
}

// The furthest-back date worth showing. Anything older reads better as days,
// and an unbounded year count would be noise in a tooltip.
var MAX_AGE_DAYS = 365

function ageLabel(ms) {
  var value = Number(ms)
  // A non-numeric or negative age is treated as "just happened" rather than
  // rendered as NaN, which is how this read before.
  if (!isFinite(value) || value <= 0) return "0s"
  var seconds = Math.floor(value / 1000)
  if (seconds < 60) return seconds + "s"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return minutes + "m"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h"
  var days = Math.floor(hours / 24)
  if (days > MAX_AGE_DAYS) return MAX_AGE_DAYS + "d+"
  return days + "d"
}
