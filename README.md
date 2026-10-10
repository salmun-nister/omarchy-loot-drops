<h1 align="center">Loot Drops</h1>

<p align="center">Watch Steam, Epic and GOG for games that are free to keep, and get a desktop notification the moment one appears.</p>

<p align="center"><a href="https://github.com/tcballard/omarchy-badges"><img alt="Built for Omarchy: Plugin" height="20" src="https://raw.githubusercontent.com/tcballard/omarchy-badges/75975e5b5bf75e7ede3764bcd2950046f7abfe2c/badges/v1/omarchy-plugin.svg"></a></p>

A treasure chest in your bar. Click it and a panel lists everything currently
free to keep, grouped by store, each row one click from the store page. When a
new one appears, you get a desktop notification.

**No accounts. No API keys. No logins.** It reads only the stores' own public
pages, and it never writes anything outside its own state directory.

**Inspired by [Steam Sniper](https://github.com/nille/omarchy-steam-sniper)**,
which does this for Steam alone. This adds Epic and GOG, per-store switches and
bells, and keeps a separate baseline for each store. It is an independent work
with no third-party code vendored — see [credits](CREDITS.md) for the lineage.

<p align="center"><img alt="Loot Drops showing four games free to keep, grouped by store" src="preview.png" width="410"></p>

**Preview:** a real screenshot from Omarchy 4.0.4-1 on Hyprland, taken from the
live desktop with the panel open. The stores and games in it were real at capture
time, so it will not match what the panel shows later. Desktop acceptance
evidence is in [docs/ACCEPTANCE.json](docs/ACCEPTANCE.json).

## Install

```bash
omarchy plugin add https://github.com/salmun-nister/omarchy-loot-drops --enable right
```

Or clone it yourself and rescan:

```bash
git clone https://github.com/salmun-nister/omarchy-loot-drops \
  ~/.config/omarchy/plugins/salmun-nister.loot-drops
omarchy-shell shell rescanPlugins
omarchy plugin enable salmun-nister.loot-drops right
```

Nothing else to install. `python3` and `curl` are already present on Omarchy.

## Using it

| Action | What happens |
| --- | --- |
| Left-click the chest | Open the panel |
| Middle-click the chest | Refresh the three stores now |
| Click a game | Open its store page and close the panel |
| `r` | Refresh the three stores now |
| `e` | Enable or disable that store |
| `n` | Mute or unmute notifications for that store |
| `j` / `k` | Scroll down / up |
| `?` | Show or hide the shortcut list |
| `Esc` | Close the panel |

The shortcut list lives in the README. If you have forgotten it while the panel
is open, press `?` — or click the `?` in the panel's bottom-right corner — and
it appears above the buttons until you press it again.

A coloured dot sits on the top right of the chest while there are free games you
have not opened the panel to see. Opening the panel clears it; a game that turns
up later lights it again. It is independent of the notification bells, so a
muted store still shows a dot for something you have not looked at. Like the
notification-center badge, it is drawn over the icon rather than beside it, so
the bar does not change width as games arrive.

Each enabled store gets its own section in the panel, headed by the store's mark
— the real Steam and GOG logos, and an **E** for Epic, which Nerd Fonts has no
mark for. The header carries two controls: a **switch** that stops or resumes
watching that store entirely, and a **bell** that mutes or unmutes its
notifications. Games sit slightly indented under their store name. Both sit in a hit box the height
of the row and light up on hover, so they are easy to hit and read as controls.
Both take effect immediately, and both are saved to your `shell.json`.

`e` and `n` act on whichever store your **pointer is over**, falling back to
whichever store the keyboard cursor last landed on. Hovering a store's name or any
of its games retargets them, so you do not have to move the cursor first.

Clicking the bell keeps the store listed but silent — a muted store is visibly
different from one you have switched off. A store you have switched off collapses
to a faded row with no games under it, because it is no longer being watched;
its switch stays live so you can turn it back on from there.

Right-click does nothing, deliberately.

The panel lists every free game, however many there are; it scrolls with the
wheel, and the keyboard cursor scrolls itself into view.

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
{ "id": "salmun-nister.loot-drops", "refreshMinutes": 180, "gogNotify": false }
```

The switches and bells in the panel write to the same keys, so you can also set
them by hand while the plugin is off. Switching a store **off** stops it being
fetched at all — no request, no rows, no notifications. Switching it back **on**
re-records silently rather than announcing everything it missed while you had it
off.

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
| A store header on its own | That store is on and has nothing free today. Normal, and it can still be switched off from there. |
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
`~/.local/state/salmun-nister.loot-drops/`. Removing the plugin leaves it
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

Intended target: Omarchy 4 / Hyprland. Tested live on **Omarchy 4.0.4-1** with
Hyprland on X11-less Wayland, kernel 7.2.5-3-omarchy: the widget loads on the bar,
the panel opens and closes, all three stores resolve, a desktop notification
fires on a newly free game and does not repeat, and the per-store switch and bell
states render. GOG's success path is still fixture-only, because no giveaway was
live when it was tested. A vertical bar has not been observed.

Portable validation additionally covers parsing, the URL allowlist and the
notification diff. See [acceptance evidence](docs/ACCEPTANCE.json) for the exact
commands and results.

## Credits

Built from [Build Omarchy Plugins](https://github.com/tcballard/build-omarchy-plugins)
guidance and the Omarchy template set. No third-party code is vendored; lineage
is recorded in [CREDITS.md](CREDITS.md).

## Licence

[MIT](LICENSE). Third-party software and media retain their own licences.
