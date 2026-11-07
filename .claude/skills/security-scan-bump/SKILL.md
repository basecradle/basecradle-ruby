---
name: security-scan-bump
description: How to respond when the daily dependency security scan files `[SECURITY] Dependency Advisories Against main (Daily Scan)` or `Daily Dependency Security Scan Could Not Reach a Verdict` on this repo — find what holds the fixed version back, move it on its own branch, verify against a refreshed advisory database, dismiss what does not apply in `.bundler-audit.yml`, and close the issue by hand. Also use when re-running the scan by hand or bumping its pinned bundler-audit. The scan's invariants live in CLAUDE.md → The Daily Dependency Security Scan.
---

# Responding to the Daily Dependency Security Scan

The scan (`.github/workflows/dependency-security-scan.yml`, 14:37 UTC; the decisions are in `script/dependency_security_scan.rb`) resolves what the `Gemfile` and `basecradle.gemspec` allow, audits it, and files at most two issues. This is the core's `security-scan-bump` procedure, cut to what applies to a gem that commits no lockfile and runs no production.

## What Is Different Here

- **No lockfile is committed**, so every scan — and every CI job — resolves the newest versions the constraints allow. An advisory that stands therefore means **no fixed version is resolvable**: upstream has not released one, a constraint in the `Gemfile` or the gemspec holds it back, or one of the Rubies the scan resolves under (every Ruby in the CI matrix) does. The *Installed* column lists every version the advisory was found in across those resolutions. When upstream releases a fix the constraints already allow, the next scan notes the advisory as no longer reported without anyone touching the tree.
- **The gem declares no runtime dependency**, so nothing the scan finds ships to anyone who installs it. These gems run in CI and on contributors' machines. That narrows the reach; it does not make the advisory someone else's problem — CI runners hold this repo's checkout and, on a tag, its publish path.
- **There is no deploy.** The core's deploy token, both-hosts read and Dependabot fan-out do not apply. A bump here is an ordinary PR, shipped with the `ship-a-pr` skill.
- **No PR's CI runs bundler-audit**, so there is no PR to pause: the daily issue is the only place an advisory surfaces.

## When the Advisories Issue Is Filed

1. **Read the issue's table and its routing.** `needs-human` means something is High or Critical and `@origin` has been paged; `needs-capital` means everything is lower or unrated.
2. **Find what holds the fixed version back.** Read the advisory's patched versions, then reproduce the scan's resolution locally, under each Ruby the matrix tests that you have (the CI matrix's own runs show the rest):
   ```bash
   d=$(mktemp -d) && BUNDLE_GEMFILE=$PWD/Gemfile bundle lock --update --lockfile "$d/Gemfile.lock"
   bundle-audit check "$d" --update --config "$PWD/.bundler-audit.yml"
   ```
   `--update` matters on both: without it `bundle lock` starts from your own stale `Gemfile.lock`, and `bundle-audit` reads a stale database. **Confirm the database holds the advisory you are fixing** (`grep -rl <GHSA-id> ~/.local/share/ruby-advisory-db/gems/<gem>/` names a file) — a stale database reads clean on a vulnerable resolution too. `bundle exec gem dependency <gem> --reverse-dependencies` or the lockfile's dependency tree shows who constrains it. Remove the temp directory when done.
3. **Move the constraint, on its own branch, one concern per PR.** A floor on a transitive gem (`gem "rack", ">= 3.2.8"` in the development group, with a comment naming the advisory) or a widened cap on a direct one. Never raise the gemspec's `required_ruby_version` or add a runtime dependency to clear a dev-only advisory: both reach every user of the gem. Verify with the commands in step 2 (now clean) and `bundle exec rake`.
4. **If no fixed version exists**, or the advisory cannot apply here (read its preconditions against how this repo uses the gem — most dev tooling never parses untrusted input), dismiss it in `.bundler-audit.yml` at the repo root, with a comment saying why and until when:
   ```yaml
   ignore:
     - GHSA-xxxx-xxxx-xxxx # <gem>: <why it does not apply here>; revisit when <condition>
   ```
   The scan reads that file. Closing the issue dismisses nothing: the next scan files a new one, and pages again if it is High or Critical.
5. **Read the Critical and High advisories against this repo, on the issue**: which had reach (a CI job, a contributor's machine), and whether anything needs investigating beyond the bump.
6. **Close the issue by hand** once the scan that follows the fix reports it clean ("The scan of `main` at … is clean") — the workflow never closes it.

## When the Could-Not-Reach-a-Verdict Issue Is Filed

A scanner crashed: the `Gemfile` would not resolve, the advisory database would not update, or `bundle-audit` is missing or could not read its report. Until it is fixed the clock is stopped, and the heartbeat is withheld, so Better Stack pages after a day plus grace as well.

1. Read the run's log (linked from the issue). `gh run view <id> --log --repo basecradle/basecradle-ruby` works with this bot's `actions: read`.
2. Fix the cause on its own branch. A Gemfile that will not resolve breaks CI too; a stale pinned `bundler-audit` that cannot read the database is bumped in the workflow's `env:` (`BUNDLER_AUDIT_VERSION`), which Dependabot cannot see.
3. Ask the capital to re-run the workflow by hand (below). The run that reaches a verdict closes the issue itself; that run is the verification.

A run that dies before it can file anything (the App token will not mint, Ruby will not install) is only a red run in the Actions tab plus, a day later, the heartbeat's page.

## Re-running by Hand

This bot's App has `actions: read`, so it **cannot start a workflow run**. Ask the capital on the issue with `needs-capital`: "dispatch `Dependency Security Scan` on `main`" (it runs `gh workflow run dependency-security-scan.yml --ref main` under its operator credential). Read the result yourself with `gh run list --workflow dependency-security-scan.yml`.

**Dispatch on `main`, never on a fix branch.** A run on any ref reads and writes the same two issues: a fix branch that resolves clean would tell the advisories issue `main` is clean, rewrite its marker, and close the could-not-run issue, while `main` is still affected, and the next scheduled run would then file the advisory as new and page again. Verify a fix branch locally (step 2 above); the scheduled run after it merges is the verification. The one deliberate exception is a proof of the filing path on a throwaway branch (#267's record), whose test issue is closed, labels removed, before the next scheduled run.
