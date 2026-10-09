<h1 align="center">Loot Lightning</h1>

<p align="center">Watch Steam, Epic and GOG for games that are free to keep, and get a desktop notification the moment one appears.</p>

<p align="center"><a href="https://github.com/tcballard/omarchy-badges"><img alt="Built for Omarchy: Plugin" height="20" src="https://raw.githubusercontent.com/tcballard/omarchy-badges/75975e5b5bf75e7ede3764bcd2950046f7abfe2c/badges/v1/omarchy-plugin.svg"></a></p>

A lightning bolt in your bar. Click it and a panel lists everything currently
free to keep, grouped by store, each row one click from the store page. When a
new one appears, you get a desktop notification.

**No accounts. No API keys. No logins.** It reads only the stores' own public
pages, and it never writes anything outside its own state directory.

**Inspired by [Steam Sniper](https://github.com/nille/omarchy-steam-sniper)**,
which does this for Steam alone. This adds Epic and GOG, per-store switches and
bells, and keeps a separate baseline for each store. It is an independent work
with no third-party code vendored — see [credits](CREDITS.md) for the lineage.

**Preview:** a real on-device screenshot is pending. No screenshot or desktop
acceptance is claimed.

## Install

```bash
omarchy plugin add https://github.com/salmun-nister/omarchy-loot-lightning --enable right
```

Or clone it yourself and rescan:

```bash
git clone https://github.com/salmun-nister/omarchy-loot-lightning \
  ~/.config/omarchy/plugins/salmun-nister.loot-lightning
omarchy-shell shell rescanPlugins
omarchy plugin enable salmun-nister.loot-lightning right
```

Nothing else to install. `python3` and `curl` are already present on Omarchy.

## Using it

| Action | What happens |
| --- | --- |
| Left-click the bolt | Open the panel |
| Middle-click the bolt | Refresh now |
| Right-click the bolt | Open the first enabled store |
| Click a game | Open its store page and close the panel |
| `r` | Refresh now |
| `1` / `2` / `3` | Open Steam / Epic / GOG |
| `q` | Disable the plugin |
| `Esc` | Close the panel |

Each enabled store gets its own section in the panel: its name, a count or a
reason, and its games. A store with its bell switched off shows a crossed-out
bell, so a muted store is visibly different from a disabled one.

## Settings

Set these on the widget's entry in `~/.config/omarchy/shell.json`, or through the
Omarchy settings UI. They hot-reload on save.

| Setting | Default | What it does |
| --- | --- | --- |
| `refreshMinutes` | `180` | How often to check the enabled stores (5–180). |
| `steamEnabled` | `true` | Watch Steam. |
| `epicEnabled` | `true` | Watch the Epic Games Store. |
| `gogEnabled` | `true` | Watch GOG. |
| `steamNotify` | `true` | Notify when a Steam game goes free. |
| `epicNotify` | `true` | Notify when an Epic game goes free. |
| `gogNotify` | `true` | Notify when a GOG giveaway runs. |
| `steamCountry` | `""` | Optional two-letter Steam store country (`US`, `DE`, `GB`). Empty lets Steam choose. |

```json
{ "id": "salmun-nister.loot-lightning", "refreshMinutes": 180, "gogNotify": false }
```

Switching a store **off** stops it being fetched at all — no request, no rows, no
notifications. Switching it back **on** re-records silently rather than announcing
everything it missed while you had it off.

## How it decides

Free giveaways last for days, so three hours is long enough. The panel also
refreshes itself when you open it and the data is more than four hours old, which
covers a laptop that was asleep.

The first run is deliberately quiet. It records what is already free without
announcing it, so installing the plugin does not produce a wall of notifications
for games that were free before you asked.

Each store is fetched separately, so one being slow or down never delays or hides
the other two. A failed check never erases what you already had: the panel keeps
showing the last good list with the reason attached.

The states are kept apart rather than collapsed into one "no games" message:

| What you see | What it means |
| --- | --- |
| `N games free to keep` | Fetched, and there are some. |
| `Nothing free right now` | Fetched, and there are none. |
| `No giveaway running` | GOG answered: no giveaway today. Normal. |
| `Not checked yet` | No successful check has happened yet. |
| `Could not reach <store>` | The request failed; the old list is still shown. |
| `Store returned an unexpected response` | The page did not look like what we expected. |

## What it talks to

Three public endpoints, one request each per refresh, and nothing else:

| Store | Host |
| --- | --- |
| Steam | `store.steampowered.com` |
| Epic | `store-site-backend-static.ak.epicgames.com` |
| GOG | `www.gog.com` |

Only those three hosts are ever opened. Every link is checked against the store's
own address before your browser is launched, and every game title is stripped of
markup and control characters before it is displayed or sent to the notification
server. See [security](SECURITY.md).

Your plugin state lives in one file, `seen.json`, under
`~/.local/state/salmun-nister.loot-lightning/`. Removing the plugin leaves it
behind; delete that directory if you want a clean slate. Nothing else on your
system is touched.

## Not included

Upcoming and announced games, cover art, countdown timers, permanently-free and
free-to-play titles, and store selection for Epic or GOG. GOG's giveaway is a
limited-time claim-and-keep promotion, which is what this tracks — not GOG's
larger free catalogue.

## Development

```bash
./tests/run          # portable checks
./tests/harness/run  # the real widget in a real Quickshell, against live stores
```

[Build, run and remove](docs/DEVELOPMENT.md) · [Design record](DESIGN.md) ·
[Architecture](ARCHITECTURE.md) · [Release process](docs/RELEASE.md)

## Compatibility

Intended target: Omarchy 4 / Hyprland. Exact installed Omarchy versions tested:
**none yet**. Portable validation covers structure, parsing, the URL allowlist and
the notification diff; it does not establish live desktop compatibility. Record
actual tests in [acceptance evidence](docs/ACCEPTANCE.json).

## Credits

Built from [Build Omarchy Plugins](https://github.com/tcballard/build-omarchy-plugins)
guidance and the Omarchy template set. No third-party code is vendored; lineage
is recorded in [CREDITS.md](CREDITS.md).

## Licence

[MIT](LICENSE). Third-party software and media retain their own licences.
