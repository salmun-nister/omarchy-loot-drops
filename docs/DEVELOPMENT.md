# Develop and test the plugin

## Checks

```bash
./tests/run          # portable: structure, model, QML lint, helper behaviour
./tests/harness/run  # live: the real widget against the three real stores
```

`./tests/run` is what CI runs. It needs Node 22+ and, for the QML lint pass, the
real Qt `qmllint` at `/usr/lib/qt6/bin/qmllint` plus the shell modules. Missing
pieces are skipped with a message rather than silently passing.

A green `./tests/run` does **not** establish live desktop acceptance. The harness
covers transport; it does not cover what the panel looks like on your bar.

## Working on the widget

`Model.js` holds everything testable without a desktop — parsing, the URL
allowlist, the title scrub, the seen-state diff and the notification copy.
`BarWidget.qml` holds transport, persistence and rendering. Prefer putting logic
in `Model.js`: it runs in plain Node, so tests are fast and free of Quickshell.

Fixtures live in `tests/fixtures/`. `steam-free.json` is a real captured Steam
response; `epic-free-games.json` is hand-built to cover the cases that must be
handled — live free offer, bundle, expired offer, paid promotion, upcoming offer,
missing catalog mapping and a markup-shaped title. `gog-giveaway.json` is the
documented success shape and is **fixture-only**: GOG had nothing running on
9 October 2026, so that path is not live-verified. See `DESIGN.md`.

## Live testing on this machine

```bash
omarchy plugin add . --enable right     # or clone into ~/.config/omarchy/plugins
omarchy-shell shell rescanPlugins
```

The harness redirects the state directory, so running it will not disturb the
real `seen.json` and will not fire notifications — its settings mute all three
bells. To exercise notifications for real, install it and wait for an actual
giveaway, or temporarily point the widget at a fixture.

Worth checking by hand: the panel with one store disabled, with a bell muted,
with an empty store (GOG is empty right now, which is the easy case to observe),
and while a store is unreachable. Vertical bars are untested; the widget uses
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
`docs/ACCEPTANCE.json`. There is no published marketplace listing yet, and
submitting one is a separate, explicitly authorized step — see `DESIGN.md`.

For richer surfaces, use the current Build Omarchy Plugins generator to select
panel, overlay, menu or service contracts. Do not declare extra kinds until their
entry points exist; this plugin declares `bar-widget` and has exactly one entry
point.
