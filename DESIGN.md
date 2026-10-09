# Loot Lightning design

Decision record for `salmun-nister.loot-lightning`. Kept in the repository so a
later session extends this rather than reopening it. Accepted scope, evidence and
remaining work are at the bottom.

## Identity and prior art

- **ID**: `salmun-nister.loot-lightning`. Permanent once published.
- **Inspiration**: [nille/omarchy-steam-sniper](https://github.com/nille/omarchy-steam-sniper)
  (MIT, (c) 2026 nille). Single-store Steam giveaway watcher, already installed on
  the development machine and already hardened by marketplace review.
- **Prior-art search**: no marketplace plugin aggregates Steam, Epic and GOG.
  The nearest published plugins are single-purpose — Steam Sniper (Steam
  giveaways), `Unr3leas3d/omarchy-steam-recent` (local library, no network),
  `gigasolo/omarchy-fizzy` (polling and notification shape). A new build is
  justified; the Steam half reuses MIT code with attribution rather than
  reimplementation.
- **Distribution**: personal first, then published to `salmun-nister/omarchy-loot-lightning`
  and submitted to the marketplace. Publication is not a prerequisite for
  building, and no submission is authorized by this record.

## Surface

- **Kind**: `bar-widget` only. One entry point, `BarWidget.qml`.
- **No `service` kind.** The bar widget is always loaded and owns the refresh
  timer, the fetch, the seen-id diff and the notification. A process-wide
  service would be a second owner of the same timer for no gain.
- **No `panel` kind.** The dropdown is a private `KeyboardPanel` sibling loaded
  on demand, which the kind-selection contract explicitly permits.

## Data sources

All three were checked live on 9 October 2026. No credentials, no accounts, no
API keys, no login, no privileged operations.

| Store | Endpoint | Currently-free test | Live result |
| --- | --- | --- | --- |
| Steam | `store.steampowered.com/search/results/?maxprice=free&specials=1&infinite=1` | scrape `results_html`; `specials=1` already excludes free-to-play | 200, 2 games |
| Epic | `store-site-backend-static.ak.epicgames.com/freeGamesPromotions?locale=en-US&country=US&allowCountries=US` | `promotions.promotionalOffers[].promotionalOffers[]` with `discountPercentage: 0` **and** `endDate > now` | 200, 13 elements, 2 free |
| GOG | `www.gog.com/giveaway/api/get` | non-404 JSON body | **404** — no giveaway running |

### Findings that change the implementation

- **Epic returns an empty `url` field.** Links are built as
  `https://store.epicgames.com/p/<catalogNs.mappings[0].pageSlug>`, falling back
  to `urlSlug` when `catalogNs.mappings` is empty.
- **Epic retains expired promotions.** Without an `endDate > now` check the panel
  shows dead offers.
- **GOG's 404 is a healthy empty store**, not a failure. It must never render as
  an error, or the panel looks broken most of the time.
- **Steam has no clean API.** `search/results/` returns JSON wrapping an HTML
  blob. The parse and sanitising approach is reused from Steam Sniper.

### Rejected: GOG catalogue endpoint

`catalog.gog.com/v1/catalog?price=between:0,0` was tested and rejected. It
returned 200 with 172 KB and **420 products over 9 pages**; of the 50 in page
one, **41 have "Demo" in the title**, and the remainder are `discount: null`
permanently-free titles. It answers "everything that costs nothing" — demos,
free-to-play, old DRM-free promotions — not "a giveaway is running now". It also
has no notion of an event, so diffing it would notify on slowly-churning
catalogue noise. Permanently-free and free-to-play listings are a different
feature from "notify me when a game goes free to keep" and are deferred.

## State ownership

- **Per widget instance**: in-memory game list, per-store status and last-success
  timestamp, selected row.
- **Durable, plugin-owned**: `seen.json` in
  `$XDG_STATE_HOME/salmun-nister.loot-lightning`, written through the reused
  store helper. Shape is `{primed, stores:{steam:{ids},epic:{ids},gog:{ids}}}`,
  keyed per store so toggling one store never disturbs another store's baseline.
- **Durable user configuration**: inline in `shell.json` as booleans plus one
  string. The settings UI has no object or enum type for this; booleans are what
  it renders.

## Settings

`refreshMinutes` (integer, 5–180, default 180), `steamEnabled`, `epicEnabled`,
`gogEnabled`, `steamNotify`, `epicNotify`, `gogNotify`, `steamCountry`.

The range and step are copied from Steam Sniper so muscle memory transfers. The
**stale threshold is a constant (4 hours), not a setting** — it needs no user
tuning, and Steam Sniper likewise holds `STALE_AFTER_MS` as a constant. Steam
Sniper's 3x-interval ratio would put stale at 9 hours, too long for a giveaway
list.

## Refresh

- Timer at `refreshMinutes`, default 180 (3 hours).
- Refresh on panel open when data is absent or stale (older than 4 hours).
- Manual refresh on **middle click** of the bar mark, matching Steam Sniper's
  existing `Qt.MiddleButton` mapping. This is the plugin's only middle-click
  action by design.
- No resume-catch-up timer: at a 3-hour interval, the stale check on open covers
  a suspend longer than the interval.

## Diff and notification rules

- `primed: false` — the first successful fetch records IDs and stays silent.
- **Store off** — not fetched, not listed, no alerts.
- **Store on, bell off** — fetched and listed, no notifications.
- **Store turned off then on** — re-primes that store's baseline silently, so
  re-enabling does not produce a flood of backfill notifications.

## Failure states

Kept distinct per store, never collapsed into generic fallback:

| State | Meaning |
| --- | --- |
| `not-checked-yet` | no successful fetch yet |
| `no-giveaway-running` | GOG answered 404; healthy and empty |
| `none-free` | fetched successfully, nothing currently free |
| `unreachable` | network failure or non-200 status |
| `invalid-response` | body did not parse or had an unexpected shape |

A failed fetch **never** overwrites the last good list. The panel degrades to
stale-with-error rather than empty.

## External commands

`python3` (interpreter for the reused helpers; already an Omarchy desktop
dependency), `curl`, `omarchy-notification-send`, `omarchy-launch-browser`.
**No credentials. No privilege. No `sudo`.**

## Security invariants

These are properties of the plugin, not policy. Callers cannot bypass them.

1. Every URL reaching `omarchy-launch-browser` or the notification `--exec`
   passes a per-store canonical-host allowlist: `store.steampowered.com`,
   `store.epicgames.com`, `www.gog.com`.
2. Every title is stripped of `<`, `>`, C0/C1 and bidirectional controls and
   capped at 120 characters before reaching any sink. The notification server
   advertises body markup and body hyperlinks, and HTML decoding can revive a
   tag.
3. Fetch output is byte-capped before parsing, and seen-state is capped and
   shape-checked on read.
4. Leading dashes are stripped from notification titles, because the headline
   occupies an option position that is parsed before the positional argument.

All three feeds are attacker-controlled if a store is compromised or the
connection is intercepted.

## Reuse and attribution

`capped-run` and `seen-store` (MIT, (c) 2026 nille) plus the Steam
fetch/parse/sanitise approach are copied into the plugin with their licence
headers intact, credited in `LICENSE` and `CREDITS.md`. This is the code a
reviewer already hardened. Evaluate `omakit add run` and `omakit add store` as
alternatives: Run 0.2.1 passes the marketplace baseline clean, whereas
hand-rolled `Process` blocks draw findings — and this plugin is a
`review-required` candidate because it makes network calls.

## Verification plan

- Parser unit tests against saved fixtures for all three shapes, including
  GOG's 404 and Epic's expired-promotion case.
- Diff tests proving first-run silence and re-enable silence.
- Store and cap tests, and a QML harness, following Steam Sniper's layout.
- Live shell check of the panel.

**GOG's success-path parser is fixture-only until a real giveaway is captured.**
GOG had nothing running on 9 October 2026, so the 200 shape is implemented from
the documented JSON and is not live-verified. When GOG runs its next giveaway,
one `curl` confirms the field names. This gap is stated rather than papered
over.

## Deferred

Upcoming and announced games, cover images, countdown timers, permanently-free
and free-to-play catalogues, and region selection beyond Steam's `country`.

## Progress

Accepted: ID, single `bar-widget` kind, three store sources, per-store toggles
and bells, 3-hour refresh with stale-on-open and middle-click manual refresh,
silent first run, MIT reuse of Steam Sniper with attribution.

Completed evidence:

- Prior-art search across the marketplace and public repositories.
- All three endpoints verified live on 9 October 2026; GOG catalogue endpoint
  tested and rejected with counts.
- Repository scaffolded from the template, with the two-segment ID kept and the
  template's ID validator relaxed to accept it (verified: two-segment accepted,
  single-segment, `omarchy.*`, uppercase and trailing-dot still rejected).
- `Model.js` implemented: three parsers, host allowlist, title scrub, per-store
  seen-state diff. 23 model tests pass. Three of them caught real defects during
  development — entity decoding happening after tag stripping, an empty Steam
  object being read as "no free games", and GOG accepting an id containing a
  space.
- `BarWidget.qml` implemented and lint-clean against the real Qt `qmllint`.
  Verified in a live Quickshell harness on 9 October 2026: Steam returned Pony
  Island and Fireside Feelings, Epic returned Out of Sight and TerraScape with
  correctly built links, and GOG's 404 was read as a healthy empty store. No
  errors on any store.
- Vendored helpers tested: byte cap enforced, FIFO and symlink refused, state dir
  tightened to 0700, attribution headers asserted present.
- `./tests/run` and `omarchy plugin validate` both pass.

Remaining:

- GOG's success path is fixture-only and needs live confirmation at the next
  giveaway.
- Vertical-bar layout unobserved.
- Notification delivery unobserved on a real desktop (the harness mutes bells to
  avoid firing one).
- Marketplace listing and screenshot not started; **submission is not
  authorized**.
- Consider `omakit add run` / `omakit add store` in place of the hand-rolled
  `Process` and helper blocks, since this is a `review-required` candidate.
