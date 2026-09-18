---
name: bot-auth-setup
description: One-time and per-session setup for acting as the basecradle-ruby-ai[bot] GitHub identity — setting the local git author (never committed), and minting a short-lived installation token with the fleet helper to route `gh` and `git push`. Use when a fresh clone needs its author configured, when `gh`/`git push` fails auth, or when you need a GH_TOKEN to talk to GitHub. The identity facts (App ID, bot user id, `[bot]` handle), the no-`Co-Authored-By` rule, and the self-review-before-PR rule live in CLAUDE.md → Fleet Identity and govern at all times.
---

# Bot auth setup — acting as `basecradle-ruby-ai[bot]`

The identity facts and the standing rules (no `Co-Authored-By` trailer, self-review before every bot PR) live in `CLAUDE.md` → "Fleet Identity" and govern at all times. This skill is the mechanical setup behind them.

## Git author (local, never committed)

Set once per clone, in `.git/config` — it must **never** be staged:

```bash
git config --local user.name  "basecradle-ruby-ai[bot]"
git config --local user.email "290978458+basecradle-ruby-ai[bot]@users.noreply.github.com"
```

## Auth routing

Mint a short-lived (~1h) installation token with the fleet helper, then route `gh` and `git push` through it. `origin` is a plain unauthenticated HTTPS remote, so pushes go to the explicit token URL rather than to `origin`:

```bash
export GH_TOKEN="$(gh-app-token --token)"   # or just `gh-app-token` — --token is the default
git push "$(gh-app-token --remote)" HEAD    # authenticated https push URL
```

**The helper takes a mode, never a slug.** It reads *this* agent's own credentials from the environment (`GH_APP_SLUG`, `GH_APP_ID`, `GH_APP_BOT_USER_ID`, `GH_APP_PEM_B64` — sourced from the agent's `agent.env` by the wake-runner after the privilege drop), so there is no identity argument to pass. The three modes:

| Mode | Prints |
|---|---|
| `--token` (default) | the installation token |
| `--author` | the exact commit-author string, `basecradle-ruby-ai[bot] <290978458+basecradle-ruby-ai[bot]@users.noreply.github.com>` |
| `--remote` | the authenticated push URL, `https://x-access-token:<token>@github.com/basecradle/basecradle-ruby.git` |

`--remote` builds that URL from `GH_APP_SLUG` with the org hardcoded to `basecradle` — it does **not** look at the working directory, so it always names this repo even if you run it inside another checkout.

Anything else — notably the old `gh-app-token basecradle-ruby-ai` form — is an error: `unknown mode: … (use --token|--author|--remote)` on stderr, exit 1. Capture the token with `$(...)` **unpiped**, so a failure leaves `GH_TOKEN` empty rather than holding an error string.

Pushing to an explicit URL sets **no upstream tracking** for the branch, so `@{upstream}` stays unresolved: `gh pr create` needs an explicit `--head <branch>`, and bare `git pull` / `git diff @{upstream}...HEAD` will not work until you set one.

The helper is pure-stdlib Python — it shells out to the `openssl` CLI to sign the JWT, so `openssl` must be on `PATH` — never prints key material, and lives **outside every repo**: on the fleet server at `/usr/local/bin/gh-app-token`. Resolve it from `PATH`; never hardcode a path.
