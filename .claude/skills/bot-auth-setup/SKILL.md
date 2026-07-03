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

Mint a short-lived installation token with the fleet helper, then route `gh` and `git push` through it (origin stays SSH; push to the explicit token URL):

```bash
export GH_TOKEN="$(/path/to/gh-app-token basecradle-ruby-ai)"
git push "https://x-access-token:${GH_TOKEN}@github.com/basecradle/basecradle-ruby.git" HEAD
```

The helper (`gh-app-token` + `fleet-apps.json`) is pure-stdlib, never prints key material, and lives **outside every repo** (currently the dated `fleet-identity` folder in the Claude workspace; its permanent home moves with the dispatcher). `gh-app-token basecradle-ruby-ai --author` prints the exact commit-author string.
