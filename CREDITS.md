# Credits and provenance

**Inspired by [Steam Sniper](https://github.com/nille/omarchy-steam-sniper)** by
nille, which watches Steam alone for games that are free to keep. Loot Lightning
is an independent work: it adds Epic and GOG, a per-store panel layout, per-store
switches and bells, a separate seen-id baseline per store, and its own parsing,
allowlisting and diff logic.

**No third-party code is vendored or copied.** `lib/capped-run` and
`lib/seen-state` were written for this plugin, as were `Model.js` and
`BarWidget.qml`. Steam Sniper informed the problem framing and the general shape
of the solution — poll the store, keep a seen baseline, notify on the delta — and
none of its source is reproduced here. Nothing in this repository carries a
licence obligation to nille or to anyone else beyond this repository's own MIT
licence.

## Design lineage

The file-plumbing primitives in `lib/seen-state` — descriptor-relative opens with
`O_NOFOLLOW`, checks by `fstat` on the descriptor just opened, an exclusive
`0600` staging file, and replacement by rename — are a conventional way to write
a small private state file safely on Linux, and the same approach appears in
several MIT-licensed shell plugins. They are implemented here independently.
`tests/helpers` asserts the properties that make them safe rather than the
implementation.

## Third-party material

- No badge artwork, wallpaper, screenshot or product logo is bundled.
- Store names and endpoints belong to their respective owners and are used only
  to read public pages.
- The bar icon and status glyphs are Nerd Font glyphs already present in the
  shell's font, not redistributed artwork.

Crediting an inspiration does not grant permission to copy its code, and an
absent licence is not permission to copy. If code from another project is ever
vendored here, its origin, licence and copyright holder must be recorded in this
file and its notice reproduced in `LICENSE`, with a test asserting the notice
stays in place.

## Template

Repository template: [tcballard/omarchy-plugin-template](https://github.com/tcballard/omarchy-plugin-template)
at commit `f99681e6`, template version 0.1.0, MIT, (c) 2026 Tom Ballard. The pin
is recorded in `.template/source.json` along with the local adjustments.

Plugin conventions follow [build-omarchy-plugins](https://github.com/tcballard/build-omarchy-plugins).
