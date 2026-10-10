# Architecture

`BarWidget.qml` is the single entry point. It owns the bar mark, the panel, the
refresh timer, the fetch processes and the seen-state file. `Model.js` holds the
parsing, allowlisting, diffing and notification copy. The split is deliberate:
everything that can be tested without a desktop lives in `Model.js`, and the
widget owns only transport, persistence and rendering.

There is no `service` kind. The bar widget is always loaded, so it already
outlives any panel the user opens; a process-wide singleton would be a second
owner of the same timer for nothing. Add one only if the widget can be disabled
while notifications must continue, and document the shutdown path when you do.

## Files

| File | Role |
| --- | --- |
| `BarWidget.qml` | Entry point. Transport, persistence, panel rendering, lifecycle. |
| `Model.js` | Pure functions: parse, allowlist, diff, notify, copy. No I/O. |
| `lib/capped-run` | Byte cap on a child's stdout, killing its process group when the cap is exceeded. |
| `lib/seen-state` | Private, atomic, no-follow read/write of `seen.json`. |
| `tests/` | Portable checks, plus a live harness. |

## State

One durable file, `~/.local/state/salmun-nister.loot-lightning/seen.json`,
written through `lib/seen-state`. It holds a baseline per store:

```json
{ "primed": true, "stores": { "steam": { "ids": ["405640"], "primed": true } } }
```

Everything else is per-instance and in memory: the game list, each store's error
and timestamp, and the cursor. Settings live inline in `shell.json` as widget
settings, not in this file.

Baselines are per store so disabling one store cannot disturb another. A store
with no baseline records silently; a store that was disabled re-records silently
on return rather than announcing what it missed.

## Fetching

`curl` per enabled store, each in its own `Process`, so a slow or hanging store
cannot delay the others and one failure cannot mask the rest. Output is capped by
`lib/capped-run` before anything is parsed.

Steam has no clean giveaway API, so its infinite-scroll search endpoint is read
and the HTML rows parsed. Epic returns JSON, filtered to zero-discount windows
whose `endDate` is still in the future, because Epic keeps expired promotions in
the array. GOG answers `404` when nothing is running, which is a healthy empty
store rather than an error.

## Trust boundary

Every network value is treated as untrusted, because it is attacker-controlled
if a store is compromised or the connection is intercepted. Two rules hold
everywhere, and both are enforced in `Model.js` rather than at call sites:

1. **Links are rebuilt or allowlisted.** Steam URLs are rebuilt from a
   digits-only id; Epic and GOG links pass `safeUrl`, which requires https, the
   store's exact host, and a bounded, credential-free authority. Anything else
   becomes the store's search page. `diffStore` re-applies this before an alert
   reaches the notification server.
2. **Titles are plain text.** Tags are stripped, entities are decoded, then
   angle brackets, control characters and bidirectional overrides are removed
   and the result is capped. Every `Text` element that shows a store-provided
   string uses `Text.PlainText`.

Leading dashes are stripped from notification headlines, because the headline
occupies an option position that is parsed before the positional argument.

## Rendering

The panel is a private `KeyboardPanel` sibling, not a top-level `panel` kind. It
lists enabled stores in a fixed order, each with its games and a state line.
Games from all stores form one flat list for the cursor, so arrow keys move
through the whole panel while the layout stays grouped.

External text uses `Text.PlainText` throughout, including inside delegates.

## Testing

`tests/model.test.mjs` loads `Model.js` as plain JavaScript and drives it against
saved fixtures: the real Steam payload, a hand-built Epic payload covering
expired, paid and upcoming offers, and GOG's giveaway and 404 shapes. It is where
the URL allowlist, the title scrub and the three silencing rules are pinned.

`tests/qml/lint` runs the real Qt `qmllint` against a shim for `qs.Commons` and
`qs.Ui`. The `qmllint` on `PATH` is a stub that reports nothing; the script uses
`/usr/lib/qt6/bin/qmllint` and fails on any error or syntax warning.

`tests/helpers` asserts the byte cap holds, that a FIFO or symlink planted at
the state file is refused rather than followed, that the directory ends up
private, and that the byte cap holds against a child that keeps writing.

`tests/harness/run` loads the real widget into a real Quickshell instance against
the live stores, with a stubbed bar and a temporary state directory. It is the
only check that exercises transport, and it is not part of `./tests/run`.

Node is a development dependency for the portable checks; it is not used by the
runtime widget.
