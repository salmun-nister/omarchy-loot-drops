# Security

Do not post credentials or sensitive exploit details in a public issue. Use GitHub
private vulnerability reporting if enabled; otherwise ask the maintainer for a
private reporting channel before sending sensitive details. No response-time
commitment is implied.

## What this plugin touches

This plugin runs unsandboxed inside your long-running `omarchy-shell` process.
That is true of every shell plugin, and it is why the surface below is kept short
and explicit.

| Kind | Detail |
| --- | --- |
| Network | Three hosts, one GET each per refresh. No credentials, no accounts, no `sudo`. |
, `omarchy-notification-send`, `omarchy-launch-browser`. All named with absolute or resolved paths and argv, never a shell string. |
| Files | One: `~/.local/state/salmun-nister.loot-drops/seen.json`, written atomically through a no-follow helper. |
| Privileged operations | None. |
| Credentials read | None. |

Nothing is sent anywhere except to the three store endpoints and, when you click,
your own browser.

## The trust boundary

Everything read from a store is attacker-controlled if that store is compromised
or the connection is intercepted. Two rules hold across every code path, and both
are enforced in `Model.js` so no call site can skip them:

**Links.** A URL is never launched because the network said so.

- Steam URLs are rebuilt from a digits-only app id; the response's `href` is
  discarded rather than validated.
- Epic and GOG links pass `safeUrl`, which requires `https`, the store's exact
  host, an authority with no credentials and no port, and a bounded length. The
  check compares the whole authority, so `store.steampowered.com.evil.test` and
  `user@store.steampowered.com` both fail.
- Anything rejected becomes that store's search page, never an empty launch.
- `diffStore` re-applies the allowlist before an alert reaches the notification
  server, so a URL cannot be laundered through the seen-state comparison.

**Titles.** A title is rendered as plain text, never markup. Tags are stripped,
HTML entities are decoded, then angle brackets, C0/C1 control characters and
bidirectional overrides are removed and the result is capped at 120 characters.
Numeric entities are decoded through a code-point check that drops surrogates, so
`&#x202e;` cannot smuggle a bidi override past the literal filter. This matters
because the notification server advertises body markup and body hyperlinks.

**Notification headlines.** Leading dashes are stripped, because the headline
occupies an option position that is parsed before the positional argument and a
title of exactly `--exec` would otherwise be read as a flag.

**Response size.** Every response is read through `lib/capped-run`, which kills
a child that exceeds its cap, so a hostile or broken endpoint cannot stream
unbounded data into the shell process.

**State file.** `lib/seen-state` opens the directory and file with
`O_NOFOLLOW`, refuses anything that is not a regular file owned by you, caps the
read, and replaces the file by rename so a reader never sees a partial write.
`tests/helpers` asserts that a planted FIFO and a planted symlink are both
refused, and that a failed write leaves the previous file whole.

## What is deliberately absent

No agent, model or AI integration. No credential broker. No privileged setup. No
install hook, and nothing is fetched at plugin-add time. No store account is ever
read, and no cookie or token is stored, forwarded or accepted.

Because there is no automated claim or purchase path, the worst outcome of a
compromised response is a wrong game title and a link to a store page you can
see before you act on it.

## Reporting

Report a problem privately. A useful report includes the store involved, what you
expected, and what happened — a title that rendered oddly is the most valuable
kind of report, because it means the scrub missed something.
