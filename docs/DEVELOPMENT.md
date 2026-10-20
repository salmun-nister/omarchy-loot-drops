# Develop and test the plugin

## Checks

```bash
./tests/run         # portable: structure, model, QML lint, helper behaviour
./tests/harness/run # live: the real widget against the four real stores
./demo/run          # manual: the real widget against a committed fixture
```

`./tests/run` is what CI runs. It needs Node 22+ and, for the QML lint pass, the
real Qt `qmllint` at `/usr/lib/qt6/bin/qmllint` plus the shell modules. Missing
pieces are skipped with a message rather than silently passing.

A green `./tests/run` does **not** establish live desktop acceptance. The harness
covers transport; it does not cover what the panel looks like on your bar.

## Demoing the panel

`./demo/run` renders the real panel against `demo/fixtures/ending-soon.json`,
opening it and leaving the window up until you close it. Two games end inside the
day, so they wear the ending-soon hourglass, and two end in a week, so they wear
the unseen coin. Steam and GOG are left off, so a live fetch cannot land on top
of the fixture.

The widget is not modified for this. `demo/run` puts `demo/bin` first on `PATH`,
where a `curl` shim answers in place of the network; `lib/capped-run` resolves the
widget's bare `curl` through that `PATH`, so the shipped transport is what runs.
The windows are shifted as a group so the furthest closes a week from now: the
committed fixture stays a genuine payload with its real gaps, and never goes
stale. `demo/run` and `demo/fixtures/` are the toolkit's demo layout, and the
`omarchy-plugin-demo` skill's preflight validates both.

## Working on the widget

`Model.js` holds everything testable without a desktop — parsing, the URL
allowlist, the title scrub, the seen-state diff and the notification copy.
`BarWidget.qml` holds transport, persistence and rendering. Prefer putting logic
in `Model.js`: it runs in plain Node, so tests are fast and free of Quickshell.

Fixtures live in `tests/fixtures/`. `steam-free.json` is a real captured Steam
response; `epic-free-games.json` is hand-built to cover the cases that must be
handled — live free offer, developer giveaway, bundle, expired offer, paid
promotion, upcoming offer, missing catalog mapping and a markup-shaped title.
Its live and upcoming windows are absolute dates, so the tests rebase them on
`now` as the fixture loads
(`epicFixture` in `model.test.mjs`) rather than storing windows that rot.
`gog-giveaway.json` is the documented success shape and is **fixture-only**: GOG
had nothing running on 9 October 2026, so that path is not live-verified. See
`DESIGN.md`.

## Live testing on this machine

```bash
omarchy plugin add . --enable right     # or clone into ~/.config/omarchy/plugins
omarchy-shell shell rescanPlugins
```

The harness redirects the state directory, so running it will not disturb the
real `seen.json` and will not fire notifications — its settings mute every
store's bell. To exercise notifications for real, install it and wait for an
actual giveaway, or temporarily point the widget at a fixture.

Worth checking by hand: the panel with one store disabled, with a bell muted,
with an empty store (GOG is empty right now, which is the easy case to observe),
and while a store is unreachable. Use the eye to hide a seen game and confirm the
per-store count replaces it, and that the footer stays put while a long list
scrolls. Amazon Luna is off by default; switching it on adds a Chromium render to
each refresh, so its first live check should confirm the grid arrives and the
panel lists the games. Vertical bars are untested; the widget uses
`bar.fontFamily` and inherits the host orientation, but nothing has been observed
on one.

## Removing

```bash
omarchy plugin disable salmun-nister.loot-drops
omarchy plugin remove salmun-nister.loot-drops
```

Removal leaves `~/.local/state/salmun-nister.loot-drops/seen.json` in place.
That is deliberate: it preserves the record of what was already free, so
reinstalling does not re-announce games that were free before. Delete that
directory if you want a clean slate. Nothing else on the system is touched, and
no Hyprland setting is modified.

## Before publishing

Record the exact verified install command and the installed Omarchy version in
`docs/ACCEPTANCE.json`. The plugin is listed in the Omarchy marketplace; its
verified snapshot is the last full commit promoted there, and a later commit
stays unverified until it is promoted through the plugin-verification form — see
`DESIGN.md`.

For richer surfaces, use the current Build Omarchy Plugins generator to select
panel, overlay, menu or service contracts. Do not declare extra kinds until their
entry points exist; this plugin declares `bar-widget` and has exactly one entry
point.
