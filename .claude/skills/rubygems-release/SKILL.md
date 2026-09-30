---
name: rubygems-release
description: Step-by-step procedure for releasing the basecradle gem via RubyGems Trusted Publishing (OIDC) — the one-time pending-publisher registration form and its contractual field values, the tag-triggered rehearsal→publish job graph, the tag mechanics, and the re-trigger-after-a-fixed-bug commands. Use when cutting a release, registering or debugging the RubyGems trusted publisher, editing `.github/workflows/release.yml`, or re-triggering a failed publish. The invariants (release PRs never carry a closing keyword; close the release issue by hand after live verify; captain's job ends at the version bump + changelog; the capital actuates the gate; the workflow filename + environment names are contractual) live in CLAUDE.md → Releasing and govern at all times.
---

# Releasing the `basecradle` gem — RubyGems Trusted Publishing (OIDC)

The invariants live in `CLAUDE.md` → "Releasing — RubyGems Trusted Publishing (OIDC)" and govern at all times. This skill is the procedure behind them.

The model mirrors the Python pipeline: **tag → build → rehearse → capital approval → publish**, with **zero stored credentials** via [RubyGems Trusted Publishing](https://guides.rubygems.org/trusted-publishing/) (GitHub Actions OIDC). The Python release pipeline at `../basecradle-python/.github/workflows/release.yml` is the template it was adapted from.

- The trigger is a `v*` git tag.
- RubyGems has no TestPyPI equivalent; the "rehearsal" is building the `.gem` and verifying a clean local install before the gated push.
- **Bootstrap (resolved):** RubyGems **does** support a *pending* trusted publisher for a not-yet-existent gem (verified 2026-06-04 against the [official guide](https://guides.rubygems.org/trusted-publishing/)). Register it before the first publish; RubyGems converts it to a normal publisher after the first successful push. No hand-pushed API-key flow is ever needed. A pending (or permanent) trusted publisher is **not** consumed by a failed run.

## One-time prep — registering the trusted publisher (capital, via its operator credential)

The capital does this once, operating the gem-owner credential at RubyGems — it is **not** a human gate. These field values are **contractual** — the `release.yml` workflow must match them verbatim (a mismatch breaks the OIDC trust and the publish 403s):

1. Sign in at https://rubygems.org (enable account MFA — recommended).
2. Open the pending-publisher page: https://rubygems.org/profile/oidc/pending_trusted_publishers → **Create**.
3. Fill the form exactly:

   | Field | Value |
   |---|---|
   | RubyGems gem name | `basecradle` |
   | Repository owner | `basecradle` |
   | Repository name | `basecradle-ruby` |
   | Workflow filename | `release.yml` |
   | Environment | `rubygems` |
   | Workflow repository owner/name (optional) | *leave blank* |

   ⚠️ The form pre-suggests `release` for Environment — **overwrite it with `rubygems`**. Ecosystem convention: the publish environment is named for the destination registry (Python uses `pypi`; Ruby uses `rubygems`), and it must equal the `environment:` key in the release workflow's publish job.
4. Submit. The first successful `0.0.1` publish converts this pending publisher into a normal one for the gem.

The matching **GitHub side** — a `rubygems` environment whose protection rule requires a review from `drawkkwast` — is configured (required reviewer: `drawkkwast`). That reviewer identity is the **credential the capital operates** (via local `gh`), not the founder's action: the capital approves the gate. Per the constitution it is a **training wheel to retire** toward bot-native auto-publish, not a permanent fixture.

## The pipeline (mechanism)

The pipeline (`.github/workflows/release.yml`) is built and proven (`0.0.1` shipped 2026-06-04). On a `v*` tag it runs **rehearsal** (build the gem; refuse a tag that does not name the version just built; verify a clean `gem install` + `require` on the 3.2 floor) → **publish** (gated by the `rubygems` environment, then `rubygems/release-gem` runs `bundle exec rake release` via OIDC). `release-gem` also generates sigstore build attestations.

- **`rake release` is provided by `bundler/gem_tasks`** (required in the `Rakefile`). In a tag-triggered run the tag already exists, so bundler's `already_tagged?` guard skips tagging/SCM-push (`release-gem` runs `git fetch --tags --force` to make the tag visible) — the run does only the gem push. Do not pre-create the tag with `rake release` locally; tag with the derived command under **Tagging** below.
- **The tag must name the version being built.** Rehearsal's tag guard compares `${GITHUB_REF_NAME#v}` against the version on the gem it just built and fails with an `::error::` naming both, so a mistyped tag stops in seconds instead of after the gate is approved. The version it accepts is bundler's `version_tag` — `"v" + Gem::Version#to_s`, which **normalizes** a hyphenated prerelease (`1.0.0-rc1` in `version.rb` → tag `v1.0.0.pre.rc1`, matching the built gem's filename). The error names the tag to use; take it literally rather than re-typing the raw `version.rb` literal.
- **Captain vs. capital split.** The captain's (this repo's) release responsibility **ends at the version bump + changelog**. From there the capital takes over: it tags, runs the pipeline, approves the `rubygems` env-gate via its operator credential, verifies the live install, and closes the release issue. (Mirrors the harness's four-owner framing — *"A release is not done at PyPI…"*.)

## Tagging — derive the version, never type it

The tag is created on whatever commit you are standing on, so start from an up-to-date `main`, in the repo root:

```bash
git fetch origin main && git switch main && git merge --ff-only FETCH_HEAD
V="v$(ruby -e 'print Gem::Specification.load("basecradle.gemspec").version')" && git tag "$V" && git push origin "$V"
```

The version is **derived, never typed**: it is the same `Gem::Version#to_s` that names the gem the rehearsal's tag guard checks (#184), so the tag cannot disagree with the tree it names, and a prerelease normalizes on its own — nobody has to know that `1.0.0-rc1` in `version.rb` tags as `v1.0.0.pre.rc1` — leaving that guard as the backstop against a hand-edited tag (decided in #186).

Three things the chain depends on:

- **The fetch is not optional.** Derivation proves the tag matches the tree you are standing on — never that it is the right *commit*. Tag a stale `main` and the guard passes by construction, because tag and tree now come from one source: a stale checkout publishes the wrong commit with nothing left to catch it. The hand-typed procedure this replaced got an independent second opinion out of the guard; derivation trades that away, and the fetch is what buys it back.
- **Keep the derivation a bare assignment at the head of one `&&` chain.** A bare `V=...` returns its command substitution's status, so a failed load short-circuits before anything is tagged. `export V=...` and `local V=...` return 0 instead — and run from anywhere but the repo root the relative gemspec path fails to load, `V` collapses to a bare `"v"`, and `git tag "$V"` pushes a junk `v` tag, which matches the release workflow's `v*` trigger. An emptiness test is no substitute: `[ -n "v" ]` passes.
- **Re-run only the push, never the whole chain.** If `git push` fails (expired token, network) the local tag already exists, and re-running the chain dies at `git tag` with `already exists` (rc 128) without ever reaching the push.

## When the tag guard fails

Not a workflow bug — the tag and `lib/basecradle/version.rb` disagree, and nothing has been published. Decide which one is right:

- **The tag was mistyped** (the tree holds the version you meant) → delete it and re-tag with the version the error names, which was computed from the gem CI built at the tagged commit: `git tag -d vWRONG && git push origin :refs/tags/vWRONG && git tag v<built> && git push origin v<built>`.
- **The bump never landed** (the tag names the version you meant) → that is captain work: a version bump + changelog PR, merged, then re-tag per the section below.

## Re-triggering after a fixed workflow bug

Fix on a PR, merge, then move the tag to the fixed commit. Fetch first — nothing in the chain does it for you, and re-tagging a stale checkout re-tags the *unfixed* commit, whereupon the run fails identically and the fix looks like it did not work:

```bash
git fetch origin main && git switch main && git merge --ff-only FETCH_HEAD
V="v$(ruby -e 'print Gem::Specification.load("basecradle.gemspec").version')" && git push origin ":refs/tags/$V" && git tag -f "$V" && git push origin "$V"
```

A workflow fix never bumps the version, so the derived `$V` names both the tag being removed and the tag being recreated. Delete the **remote** ref first: it is the one that decides what re-runs, and it does not depend on this clone's state — `git tag -d` on a tag absent locally (a fresh clone, or a previous partial attempt) exits 1 and would abort the chain before the remote was ever touched. `-f` then makes the local move idempotent.

A pending (or permanent) trusted publisher is **not** consumed by a failed run.

## Verifying live

Close the release issue by hand **only after the gem is verified live** at https://rubygems.org/gems/basecradle. A clean `gem install` is the real test — the RubyGems JSON API caches and lags. Record version + URL in the closing comment.
