---
name: rubygems-release
description: Step-by-step procedure for releasing the basecradle gem via RubyGems Trusted Publishing (OIDC) — the one-time pending-publisher registration form and its contractual field values, the tag-triggered rehearsal→publish job graph, the tag mechanics, and the re-trigger-after-a-fixed-bug commands. Use when cutting a release, registering or debugging the RubyGems trusted publisher, editing `.github/workflows/release.yml`, or re-triggering a failed publish. The invariants (release PRs never carry a closing keyword; close the release issue by hand after live verify; captain's job ends at the version bump + changelog; the capital actuates the gate; the workflow filename + environment names are contractual) live in CLAUDE.md → Releasing and govern at all times.
---

# Releasing the `basecradle` gem — RubyGems Trusted Publishing (OIDC)

The invariants live in `CLAUDE.md` → "Releasing — RubyGems Trusted Publishing (OIDC)" and govern at all times. This skill is the procedure behind them.

The model mirrors the Python pipeline: **tag → build → rehearse → capital approval → publish**, with **zero stored credentials** via [RubyGems Trusted Publishing](https://guides.rubygems.org/trusted-publishing/) (GitHub Actions OIDC). The Python release pipeline at `../python/.github/workflows/release.yml` is the template it was adapted from.

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

The pipeline (`.github/workflows/release.yml`) is built and proven (`0.0.1` shipped 2026-06-04). On a `v*` tag it runs **rehearsal** (build the gem; verify a clean `gem install` + `require` on the 3.2 floor) → **publish** (gated by the `rubygems` environment, then `rubygems/release-gem` runs `bundle exec rake release` via OIDC). `release-gem` also generates sigstore build attestations.

- **`rake release` is provided by `bundler/gem_tasks`** (required in the `Rakefile`). In a tag-triggered run the tag already exists, so bundler's `already_tagged?` guard skips tagging/SCM-push (`release-gem` runs `git fetch --tags --force` to make the tag visible) — the run does only the gem push. Do not pre-create the tag with `rake release` locally; tag with plain `git tag vX.Y.Z && git push origin vX.Y.Z`.
- **Captain vs. capital split.** The captain's (this repo's) release responsibility **ends at the version bump + changelog**. From there the capital takes over: it tags, runs the pipeline, approves the `rubygems` env-gate via its operator credential, verifies the live install, and closes the release issue. (Mirrors the harness's four-owner framing — *"A release is not done at PyPI…"*.)

## Re-triggering after a fixed workflow bug

Fix on a PR, merge, then move the tag to the fixed commit:

```bash
git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z && git tag vX.Y.Z && git push origin vX.Y.Z
```

A pending (or permanent) trusted publisher is **not** consumed by a failed run.

## Verifying live

Close the release issue by hand **only after the gem is verified live** at https://rubygems.org/gems/basecradle. A clean `gem install` is the real test — the RubyGems JSON API caches and lags. Record version + URL in the closing comment.
