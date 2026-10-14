# Loot Drops design

Decision record for `salmun-nister.loot-drops`. Kept in the repository so a
later session extends this rather than reopening it. Accepted scope, evidence and
remaining work are at the bottom.

## Identity and prior art

- **ID**: `salmun-nister.loot-drops`. Permanent once published.
- **Inspiration**: [nille/omarchy-steam-sniper](https://github.com/nille/omarchy-steam-sniper)
  (MIT, (c) 2026 nille). Single-store Steam giveaway watcher, installed on the
  development machine. No code from it is used here; see
  [Ownership and attribution](#ownership-and-attribution).
- **Prior-art search**: no marketplace plugin aggregates Steam, Epic and GOG.
  The nearest published plugins are single-purpose — Steam Sniper (Steam
  giveaways), `Unr3leas3d/omarchy-steam-recent` (local library, no network),
  `gigasolo/omarchy-fizzy` (polling and notification shape). A new build is
  justified. Every one of the installed plugins that both fetches and keeps
  state ships its own helper script — `yuters.flight-radar` in bash,
  `com.omastorm.radar` and `fred.tides` in bash, `omaproton-vpn` in Python — and
  none outsource to a shared plumbing library, which is the local convention
  followed here.
- **Distribution**: personal first, then published to `salmun-nister/omarchy-loot-drops`
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
  blob. The parse treats the embedded HTML as untrusted and sanitises before
  rendering; see [Security invariants](#security-invariants).

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
  `$XDG_STATE_HOME/salmun-nister.loot-drops`, written through the plugin's own
  `lib/seen-state` helper. Shape is
  `{primed, stores:{steam:{ids,primed},epic:{ids,primed},gog:{ids,primed}}}`,
  keyed per store so toggling one store never disturbs another store's baseline.
  Measured worst case is 3,929 bytes against a 65,536-byte cap.
- **Durable user configuration**: inline in `shell.json` as booleans plus one
  string. The settings UI has no object or enum type for this; booleans are what
  it renders.

## Settings

`refreshMinutes` (integer, 30–720, default 90), `steamEnabled`, `epicEnabled`,
`gogEnabled`, `steamNotify`, `epicNotify`, `gogNotify`, `steamCountry`.

The range is 30–720 with a 90-minute default, chosen so the slider has
headroom above the default rather than starting at its ceiling. The **stale
threshold is derived from the interval at 1.5x**, not a separate setting: it
needs no user tuning, and tying it to the interval keeps "stale" meaning the same
thing at any refresh rate. A fixed constant drifts out of proportion as soon as
the interval is changed, which is how it ended up meaning different things at
different settings.

## Refresh

- Timer at `refreshMinutes`, default 90.
- Refresh on panel open when data is absent or stale (older than 1.5x the interval).
- Manual refresh on **middle click** of the bar mark. This is the plugin's only
  middle-click action by design.
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

`/usr/bin/python3` (interpreter for this plugin's own helpers; already an
Omarchy desktop dependency, pulled in by `uwsm`), `curl`,
`omarchy-notification-send`, `omarchy-shell`. The interpreter is named
absolutely rather than taken from `PATH`, so a user with a version manager
installed does not run the helpers under a different Python than the one they
were tested against. **No credentials. No privilege. No `sudo`.**

## Security invariants

These are properties of the plugin, not policy. Callers cannot bypass them.

1. Every URL the panel can open passes a per-store canonical-host allowlist
   before it reaches `Qt.openUrlExternally`: `store.steampowered.com`,
   `store.epicgames.com`, `www.gog.com`. The notification click carries no URL
   at all — it opens the panel — so there is no second path to vet.
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

## Ownership and attribution

This plugin ships its own code. `lib/capped-run`, `lib/seen-state`, `Model.js`
and `BarWidget.qml` were written for it, informed by
[Steam Sniper](https://github.com/nille/omarchy-steam-sniper), which watches
Steam alone. No third-party code is vendored, so there is no licence obligation
beyond this repository's own MIT licence. `CREDITS.md` records the lineage and
the rule for any code vendored later.

The file-plumbing primitives in `lib/seen-state` — descriptor-relative opens with
`O_NOFOLLOW`, checks by `fstat` on the descriptor just opened, an exclusive
`0600` staging file, replacement by rename — are a conventional way to write a
small private state file safely on Linux. They are implemented here
independently, and `tests/helpers` asserts the properties that make them safe
rather than the implementation.

### Omakit considered and declined

[omakit](https://github.com/mtolhuys/omakit)'s Run and Store blocks were
evaluated. `omakit inspect` measured the current tree at roughly 20% of
sampled review findings in "process lifecycle" (processes with no observable
deadline) and 19% in "unbounded buffering", and Run addresses both.

Declined, for reasons worth recording:

- **It is not dev-only tooling.** `omakit add` copies `Run.qml` and
  `run-supervisor.py` into the plugin's `omakit/` directory; they ship and run
  inside `omarchy-shell` at runtime. Adopting them takes on Maarten Tolhuijs's
  MIT notice, which reintroduces the vendored-code obligation this plugin
  deliberately dropped.
- **Store brings a support cliff.** It refuses a group-writable XDG base. A
  `~/.local/state` at mode 775 would silently stop the state file working, and
  most users would not diagnose that. Our own helper tightens the directory to
  `0700` and continues.
- **The marketplace submission is eventual, not urgent**, so the review
  clearance Run buys is not needed yet.
- **No installed plugin uses omakit**, so there is no local precedent to follow
  (`omakit inspect` over all 32 installed plugins reports no blocks).

The one finding Run would have addressed is instead handled directly: every
fetch carries a real deadline through `fetchDeadlineMs`, passed to
`curl --max-time`, and output is capped by `lib/capped-run`.

What remains is that `omakit inspect` still reports the deadline and buffering
classes, because a static scanner cannot see a deadline expressed in QML. That
is a recorded, accepted tradeoff for an eventual submission, not an oversight.
Making the argv a static per-store binding would let the scanner read the
commands, but it would not remove the finding, since the scanner still cannot
evaluate a QML timer. Not done.

### Watchdog considered and declined

A QML-side watchdog was written, verified in isolation, and then removed. The
reasoning is worth keeping, because it is not obvious and the failure mode was
silent.

`curl --max-time` already bounds the only thing that can hang: curl's own I/O.
A fetch that overruns exits non-zero, and the per-store `onExited` turns that
into an unreachable store. The watchdog was added to cover curl ignoring its own
timeout — and that is precisely the case it handled incorrectly.

Quickshell's `Process.kill()` signals only the direct child, so a child ignoring
SIGTERM survives as an orphan still holding the pipe. That was confirmed with a
stubborn child, which was still running after the kill. The fix was to signal the
process group by id instead, but the widget passed `Process.processId` — the pid
of `capped-run`, which Quickshell spawned into its *own* process group rather
than a new one. Its pid is therefore not a group id, and `killpg` targeted a
group that does not exist. The `ProcessLookupError` was caught and treated as
"already ended", so the kill was a silent no-op; worse, on a machine where such
a group did exist, it would have signalled an unrelated one, potentially
Quickshell's own.

Two lessons recorded so this is not repeated:

1. **The test verified the wrong thing.** `--kill-group` was tested directly
   against a child started with `start_new_session=True`, where pid == pgid and
   the code was correct. The widget never called it that way. A unit test proved
   a capability the wiring did not use, and was reported as if it proved the
   wiring. The lesson: for a boundary that crosses a process boundary, test the
   path the caller actually takes, not the helper in isolation.
2. **A kill that cannot fail loudly is worse than no kill.** The failure path
   looked exactly like success, so nothing surfaced the problem. If a teardown
   cannot be verified, removing it beats shipping it broken.

`capped-run` keeps `start_new_session=True` and its own `kill_group`, which are
correct where they matter: that process starts its own child, so pid == pgid, and
the group kill runs when the byte cap is exceeded. The cross-process variant was
the only broken part and is gone.

What is lost: an ability to kill curl if curl ignores its own timeout. That
ability never worked.

## Verification plan

- Parser unit tests against saved fixtures for all three shapes, including
  GOG's 404 and Epic's expired-promotion case.
- Diff tests proving first-run silence, mute silence and re-enable silence.
- Helper behaviour tests: byte cap, FIFO and symlink refusal, private directory,
  atomic replacement under concurrent writers, and process-group teardown.
- A QML lint pass against the real Qt `qmllint`, which fails on any error or
  syntax warning.
- A live harness that loads the real widget into a real Quickshell instance
  against all three stores.

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
silent first run, and own-code helpers with a single linked credit line.

Completed evidence:

- Prior-art search across the marketplace and public repositories.
- All three endpoints verified live on 9 October 2026; GOG catalogue endpoint
  tested and rejected with counts.
- Repository scaffolded from the template, with the two-segment ID kept and the
  template's ID validator relaxed to accept it (verified: two-segment accepted,
  single-segment, `omarchy.*`, uppercase and trailing-dot still rejected).
- `Model.js` implemented: three parsers, host allowlist, title scrub, per-store
  seen-state diff. Three tests caught real defects during development — entity
  decoding happening after tag stripping, an empty Steam object being read as
  "no free games", and GOG accepting an id containing a space.
- `BarWidget.qml` implemented and lint-clean against the real Qt `qmllint`.
  Verified in a live Quickshell harness on 9 October 2026: Steam returned Pony
  Island and Fireside Feelings, Epic returned Out of Sight and TerraScape with
  correctly built links, and GOG's 404 was read as a healthy empty store. No
  errors on any store.
- Helpers written for this plugin (`lib/capped-run`, `lib/seen-state`) and tested:
  byte cap enforced at the boundary, planted FIFO and symlink refused without
  following, group-writable directory tightened to 0700, oversized payload
  refused with the old file left whole, concurrent writers leaving one whole
  payload and no temporary residue.
- The interpreter is pinned to `/usr/bin/python3`. A bare `python3` resolved
  through mise on this machine (3.15) against the system 3.14, which would have
  made the helpers run under a different Python on any other machine.
- A QML fetch watchdog was written, found to signal the wrong process group,
  and removed. See [Watchdog considered and declined](#watchdog-considered-and-declined);
  the deadline is now `curl --max-time` alone, which bounds the only thing that
  can hang.
- `./tests/run` (31 model tests plus the lint and helper suites) and
  `omarchy plugin validate` both pass.

- Panel redesign from the owner's on-device review: a switch and a clickable bell
  per store, written back through `bar.shell.updateEntryInline` as Omarchy's own
  Tray and Clock do; the mark changed from U+26A1 to U+F0726 because U+26A1 has
  Emoji_Presentation=Yes and so painted yellow in every theme instead of taking
  the palette colour; right-click and the Quit control removed; the panel body
  flattened to one row list so the cursor is a plain index, the highlight is a
  comparison rather than a linear scan, and the selected row scrolls itself into
  view when there are more games than fit.
- Qt 6.12 compatibility: the palette is now read as `Commons.Color`, because Qt
  6.12 adds a `Color` singleton to QtQuick that shadows the unqualified name.
  Not reproducible on this machine, which runs Qt 6.11.2; taken from the owner's
  Luna 0.2.2 fix on its merits.

- Panel fixes after on-device review: the Repeater was bound to a property that
  did not exist, so the panel rendered nothing while its data stayed correct; and
  `hasGames` counted header rows, which stopped the bar mark dimming. The harness
  now asserts the Repeater's instantiated row count against the model, so a
  binding that produces an empty panel fails the run. That check was verified by
  reintroducing the bug: it reports "built 0 rows from a model of 7".
- Panel copy and layout: the subtitle reads "N FREE GAMES FROM Steam, Epic, and
  GOG" using short store names, the freshness line moved to the bottom of the
  panel and centred, and the key hints were reduced to r/e/n/j-k. A store that is
  switched off now collapses to a faded header with its games dropped and its
  bell hidden, keeping only the switch.

- The panel was blank on the real bar for a second reason: the row list was a
  Column of Repeater delegates. A Repeater builds every delegate but positions
  none of them, so all seven rows sat at y = 0 and the Column reported an
  implicit height of zero. Replaced with a ListView, which lays out its rows and
  supplies positionViewAtIndex for the cursor. The harness now asserts the list's
  contentHeight against a per-row floor rather than trusting a row count; a count
  of seven was reported over a panel that drew nothing. Verified by reintroducing
  the defect: contentHeight drops from 184 to 18 and the harness fails naming the
  cause.

- Three fixes from on-device review. The bell had a hit box of a few pixels; it
  now fills a box the height of the row and highlights on hover like a game row
  does. The `e` and `n` keys acted on the wrong store, because the cursor index
  is a row index while the step is an offset in games, and nothing re-anchored
  the cursor when a toggle changed the row list; the keyboard now targets
  whichever store the cursor last landed on, and re-anchoring deliberately does
  not retarget it. The static shortcut line was replaced by a `?` beside Refresh
  now, and by the `?` key.
- A bar dot for games the panel has not been opened to see, copying the
  notification-center badge's geometry and colour. "Seen" is recorded per store in
  `seen.json` as `acknowledged`, kept separate from the notification baseline
  because a game can have been announced and still not been looked at. It is
  persisted, so a shell restart does not light the dot for games already seen.
  Building it surfaced a bug where every refresh cleared the record, because the
  diff rebuilt each store's bucket without carrying the new field.

- Five more on-device fixes. The keyboard now targets whichever store the pointer
  is over, falling back to the keyboard cursor; before, it acted on whichever
  store came first, which is why e and n only ever toggled Steam. A rule separates
  the list from the controls, the help toggle moved to its own bottom-right row
  so Refresh now is full width again, games are indented under their store name,
  and each header carries its store mark. Steam and GOG use the real Material
  Design marks from Nerd Fonts 3.5.1 (U+F04D3 and U+F0BA1); the latter moves
  between Nerd Fonts releases, so the version is pinned and tested. Nerd Fonts
  ships no Epic mark, so Epic borrows its initial.

- Panel controls from on-device review. The bell is now a bordered `Button`, the
  same component the footer's Refresh and `?` use, so the three share one
  outline, hover fill and tooltip instead of the bell being a bare glyph in a
  hand-rolled hover box. Each of the four controls carries a hover tooltip (mute
  or unmute notifications; watch or stop watching a store; refresh now;
  shortcuts). Both section rules gained 8px of clearance from the store list; the
  top gap lives inside the pinned column so the hero stays flush above the list.
  The header row is now sized to the store switch rather than a flat 30px: the
  switch draws its hover ring outside its track, so it is taller than the old
  row and the first store's ring had its top clipped against the list.

- Enter and Space opened a game that had never been selected. `selectedIndex` is
  pinned to a game on every fetch so the cursor has somewhere to land, but no row
  is drawn as selected until the keyboard cursor is engaged with j/k or an
  arrow, so the activate keys fired against a hidden selection. They are now
  gated on the cursor being active, and the panel's shortcut hint lists enter
  with the rest.

- The first move key now lands on the edge of the list: j selects the first game,
  k the last. The first move only used to engage the cursor and leave the
  highlight wherever the last refresh had pinned it, so the first j skipped past
  the first game.

- Marketplace review found a GOG parse path that threw: `gogGame` assigned `url`
  without declaring it, so a giveaway with a valid id and title but no accepted
  slug raised a ReferenceError instead of returning a row, and since the
  exception escaped the fetch callback with a zero curl exit, GOG's busy flag
  never cleared and it stopped refreshing. `url` is now declared and defaults to
  "", which reaches the existing store-search fallback, and the fetch callback
  wraps parsing so any throw becomes a store error rather than a stuck store. The
  model tests now compile under "use strict" so an undeclared assignment fails
  the suite.

- Published in the Omarchy plugin marketplace as `salmun-nister.loot-drops`. The
  maintainer accepted the `remote-build` capability at the committed snapshot —
  the flagged path is the documented alternative git-clone install, not a build
  step — and the GOG parse fix above is part of that snapshot. The `v0.1.0`
  source release is cut from the same tag. Later commits are outside the verified
  snapshot until a full-SHA update is approved, so documentation-only changes are
  batched rather than pushed on their own.

- The mouse and keyboard shared one highlight poorly: a hovered row used the
  fainter hover fill while the keyboard cursor used the selection fill, so
  hovering while a row was keyboard-selected drew two different boxes at once,
  and the hover box was a visibly weaker highlight than j/k. Both now use the
  selection fill, and the highlight is owned by whichever input was used last:
  a hover claims it and dismisses the keyboard cursor (`cursorActive`), and a
  keyboard move claims it back, so only one row is ever highlighted. The pointer
  row is remembered as `pointerIndex`; the first j/k with the pointer on a game
  now steps from that game instead of jumping to the list edge, which is what
  makes shifting from mouse to keyboard continue where the pointer left off.
  Leaving the rows clears the highlight rather than restoring the keyboard's
  position, because the pointer already dismissed it.

Remaining:

- GOG's success path is fixture-only and needs live confirmation at the next
  giveaway.
- Vertical-bar layout unobserved.
- Notification delivery unobserved on a real desktop (the harness mutes bells to
  avoid firing one).
- `omakit inspect` still reports the deadline and buffering classes, because a
  static scanner cannot see a deadline expressed in QML. Accepted for the
  listing; revisit if a reviewer flags it.
