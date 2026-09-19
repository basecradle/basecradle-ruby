---
name: bot-auth-setup
description: One-time and per-session setup for acting as the basecradle-ruby-ai[bot] GitHub identity — setting the local git author (never committed), minting a short-lived installation token with the fleet helper to route `gh`, and pushing with that token carried in the environment (never in a URL). Use when a fresh clone needs its author configured, when `gh`/`git push` fails auth, or when you need a GH_TOKEN to talk to GitHub. The identity facts (App ID, bot user id, `[bot]` handle), the no-`Co-Authored-By` rule, and the self-review-before-PR rule live in CLAUDE.md → Fleet Identity and govern at all times.
---

# Bot auth setup — acting as `basecradle-ruby-ai[bot]`

The identity facts and the standing rules (no `Co-Authored-By` trailer, self-review before every bot PR) live in `CLAUDE.md` → "Fleet Identity" and govern at all times. This skill is the mechanical setup behind them.

## Git author (local, never committed)

Set once per clone, in `.git/config` — it must **never** be staged:

```bash
git config --local user.name  "basecradle-ruby-ai[bot]"
git config --local user.email "290978458+basecradle-ruby-ai[bot]@users.noreply.github.com"
```

## Minting the token, and routing `gh` through it

Mint a short-lived (~1h) installation token with the fleet helper and export it; `gh issue`, `gh pr`, and `gh api` then all go out as the bot:

```bash
export GH_TOKEN="$(gh-app-token --token)"   # or just `gh-app-token` — --token is the default
```

**The helper takes a mode, never a slug.** It reads *this* agent's own credentials from the environment (`GH_APP_SLUG`, `GH_APP_ID`, `GH_APP_BOT_USER_ID`, `GH_APP_PEM_B64` — sourced from the agent's `agent.env` by the wake-runner after the privilege drop), so there is no identity argument to pass. The three modes:

| Mode | Prints |
|---|---|
| `--token` (default) | the installation token |
| `--author` | the exact commit-author string, `basecradle-ruby-ai[bot] <290978458+basecradle-ruby-ai[bot]@users.noreply.github.com>` |
| `--git-credential <action>` | git's credential-helper protocol — on `get` for `https://github.com`, hands git the `GH_TOKEN` already in the environment (it never mints one). Git invokes this; you never call it by hand. |

Anything else — notably the old `gh-app-token basecradle-ruby-ai` form — is an error: `unknown mode: … (use --token|--author|--git-credential)` on stderr, exit 1. Capture the token with `$(...)` **unpiped**, so a failure leaves `GH_TOKEN` empty rather than holding an error string.

The retired `--remote` mode is the one exception: it does not report `unknown mode` but refuses with the argv warning below and the current push recipe, so a stale doc that still names it hands back the fix.

## `git push` as the bot — the token rides the environment, never argv

**Never put the token in a URL** (`https://x-access-token:${GH_TOKEN}@github.com/…`): the shell expands it into `git`'s argv, and argv is readable by every account on the box (`/proc/<pid>/cmdline`, `ps`) for as long as the push runs (`basecradle-noc#694`, `basecradle#539`). `/proc/<pid>/environ`, by contrast, is readable only by the same uid — so the token goes in the environment and git reads it from a credential helper.

**On the fleet box** — where this agent runs — the NOC has already registered the minter as the agent's credential helper for `https://github.com` (in `~/.gitconfig`), so `origin` is pushed to by name and the recipe is just:

```bash
GH_TOKEN="$(gh-app-token)" git push origin <branch>
```

With `GH_TOKEN` already exported (above), plain `git push origin <branch>` is enough — the helper reads it from the environment.

Off the fleet box — a laptop clone with no helper registered — the same principle holds with an inline per-command helper instead; the canonical form (and why resetting the helper list first is load-bearing against `osxkeychain`) is the NOC's `bot-auth-setup` skill §2, `.claude/skills/bot-auth-setup/SKILL.md` in `basecradle/basecradle-noc`. It is not reproduced here because this agent runs on the fleet box.

### No remote-tracking ref for your branch — three consequences

Independent of how the push authenticates: this clone is **shallow and single-branch**, fetching only `+refs/heads/main:refs/remotes/origin/main`, so pushing a feature branch records **no** `refs/remotes/origin/<branch>`. That bites in three places:

- `gh pr create` needs an explicit `--head <branch>`.
- Bare `git pull` and `git diff @{upstream}...HEAD` will not resolve — and `git push -u` does *not* rescue them: it sets the branch config but still reports `fatal: upstream branch 'refs/heads/<branch>' not stored as a remote-tracking branch`.
- Bare `git push --force-with-lease` **fails** with `stale info`, because the lease has no recorded remote ref to check against. Fetch the ref and lease against it explicitly:

  ```bash
  git fetch origin "$BRANCH"
  git push --force-with-lease="$BRANCH:$(git rev-parse FETCH_HEAD)" origin "HEAD:$BRANCH"
  ```

  Never downgrade to a bare `--force` to get around this — the lease is the only thing protecting a concurrent push.

## About the helper

The helper is pure-stdlib Python — it shells out to the `openssl` CLI to sign the JWT, so `openssl` must be on `PATH` — never prints key material, stores nothing (the token lives in the caller's environment and dies with it), and lives **outside every repo**: on the fleet server at `/usr/local/bin/gh-app-token`. Resolve it from `PATH`; never hardcode a path.
