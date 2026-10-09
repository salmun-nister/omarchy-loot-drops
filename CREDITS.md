# Credits and provenance

**Inspired by [Steam Sniper](https://github.com/nille/omarchy-steam-sniper)** by
nille. Loot Lightning started from that plugin's single-store approach and is a
separate work: it adds Epic and GOG, a per-store panel layout, per-store toggles
and bells, and its own parsing and diff logic.

## Vendored code

Two files under `vendor/` are copied from Steam Sniper **unmodified** apart from
a two-line provenance header:

| File | Origin | Licence |
| --- | --- | --- |
| `vendor/capped-run` | `nille/omarchy-steam-sniper` | MIT, (c) 2026 nille |
| `vendor/seen-store` | `nille/omarchy-steam-sniper` | MIT, (c) 2026 nille |

MIT permits reuse, modification and redistribution provided the copyright notice
and permission notice are included. Both notices are reproduced in `LICENSE` and
the origin is recorded in each file's header. `tests/vendor` asserts the headers
stay in place, so the attribution cannot be dropped silently.

The Steam fetch, parse and sanitising approach in `Model.js` and `BarWidget.qml`
is derived from the same MIT-licensed plugin, chiefly `Model.js` there. It is
adapted rather than copied: this plugin keeps three stores, keeps baselines per
store, rebuilds Steam URLs from digits-only ids instead of validating the
response href, and marks failed fetches instead of overwriting good data.

## No other third-party material

- No badge artwork, wallpaper, screenshot or product logo is bundled.
- Store names and endpoints belong to their respective owners and are used only
  to read public pages.
- The store icons are Nerd Font glyphs already present in the shell's font, not
  redistributed artwork.

Crediting an inspiration does not grant permission to copy its code or artwork.
An absent licence is not permission to copy.

## Template

Repository template: [tcballard/omarchy-plugin-template](https://github.com/tcballard/omarchy-plugin-template)
at commit `f99681e6`, template version 0.1.0, MIT, (c) 2026 Tom Ballard. The pin
is recorded in `.template/source.json`. Local adjustments are listed there.

Plugin conventions follow [build-omarchy-plugins](https://github.com/tcballard/build-omarchy-plugins).
