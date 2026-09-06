# Codenotch (fork)

Personal fork of [vinzdg/codenotch](https://github.com/vinzdg/codenotch).
Upstream is the product; this tree adds **extra accounts** so every provider
can keep the borrowed live login and hold more logins that belong only to
Codenotch.

A macOS app that pins a small notch to a screen edge and shows how much of
each coding assistant's usage limit you have burned — and whether it is still
working, done, or waiting on you.

![Collapsed notch with hover tooltip](docs/design/frame-124-hover-tooltip.png)

## What this fork adds

The first account for each provider is still **borrowed** from the tool already
signed in on this Mac. **Add account…** in Settings signs in another login and
keeps it in Codenotch's own keychain (`com.vinz.codenotch.accounts`). Switching
the notch never writes Claude Code, Cursor, Codex, Grok, or Antigravity's
stores.

| | |
|---|---|
| Extra logins | Claude (including work profiles), Cursor, Codex, Grok, Antigravity |
| Where extras live | Codenotch keychain only |
| Switching | Changes what the notch reads. Double-click a ring to cycle. |
| Activity | Session spinner and list stay on the live tool. They hide while an extra is selected. |
| Tokens | Public vendor client IDs and registered redirects only. |

Reset clears the vault. This fork does not ship Sparkle updates from
hivinz.com; build it locally with `make run`.

## What it reads

| Provider | Live (borrowed) | Extra (this fork) |
|---|---|---|
| **Claude Code** | OAuth token in the login keychain, same endpoint as `/usage`. Two Claude Code logins are two rings — a work directory at `~/.claude-work` becomes **Claude (work)**. | Codenotch-owned OAuth; usage with the vault token only |
| **Cursor** | Editor session cookie from local SQLite | Deep Control login, Bearer usage on Cursor's API |
| **Codex** | Codex's own app server, then its rollout log | Codenotch-owned ChatGPT OAuth |
| **Antigravity** | Local language server, then Google's quota endpoint | Codenotch-owned Google OAuth |
| **Grok** | `~/.grok/auth.json` and the CLI billing endpoint | Codenotch-owned xAI OAuth; never writes `auth.json` |
| **GLM** | Z.ai Coding Plan key borrowed from Claude Code, ZCode, or OpenCode | — |

Hover a ring for its limit windows and when they reset. A thin arc spins while
a session is busy, and becomes a pulsing amber ring when one is blocked
waiting on you.

## Placement

The notch lives on any of the four screen edges. Right and left keep a
vertical column; top and bottom lay the readings out side by side. It pins
itself to the *usable* edge, so a bottom notch rests on the Dock. On a Mac
with a hardware notch, the top placement takes its shape.

Settings live in an orb below the notch. Appearance can follow the Mac, or
stay dark or light. The app itself can show a Dock icon, a menu bar icon, or
neither.

## Building

```sh
brew install xcodegen   # once
make run                # generate, build, launch a Debug build
make test               # unit tests
```

Run with `CODENOTCH_DEMO=1` for fixed sample data instead of live readings.

No signing identity is required for `make run` / `make test`. Official
notarized releases and the auto-update feed belong to
[upstream](https://github.com/vinzdg/codenotch).

## Architecture

Every provider implements `UsageProvider` (`Sources/Providers/`) and declares
its own `Fidelity` — `.official`, `.derived`, or `.manual`. `UsageStore`
(`Sources/Model/`) polls them, keeps the last good reading across launches,
and degrades every failure to a visible status rather than a made-up
percentage.

Extra accounts live in `Sources/Accounts/`. `account()` is the identity the
notch is reading; `liveAccount()` is only the borrowed login. Selecting an
extra drops that provider's cached reading so the previous account's
percentage does not flash.

The notch works in one-dimensional **stack space** (`along`/`across`);
`NotchPlacement` maps that onto screen coordinates. `NotchLayout` holds every
measurement, quoted from `docs/design/frame-124-hover-tooltip.png`.

- Upstream design spec: [`docs/specs/2026-08-28-usage-notch-design.md`](docs/specs/2026-08-28-usage-notch-design.md)
- Implementation history: [`TASKS.md`](TASKS.md)

## The honest caveat

No vendor publishes a clean "your session limit is N% used" API. Each adapter
reads whatever the owning app itself reads from, and those can change without
notice. Extra-account OAuth uses the same public clients the CLIs use, not a
Codenotch-issued secret.

**Keychain:** the live path still only reads the other tools' items. Extras
are stored under `com.vinz.codenotch.accounts` and are cleared by Reset.

**Logs:**

```sh
/usr/bin/log stream --predicate 'subsystem == "com.vinz.codenotch"' --level debug
```

## Upstream

- Product: [vinzdg/codenotch](https://github.com/vinzdg/codenotch)
- Contributing to upstream: [CONTRIBUTING.md](CONTRIBUTING.md)
- License: [MIT](LICENSE)
