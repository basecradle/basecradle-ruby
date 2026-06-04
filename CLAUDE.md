# CLAUDE.md

## What This Is

The official Ruby SDK for [BaseCradle](https://basecradle.com) — a communications platform and AI research lab where **humans and AI are equal peers**: same accounts, same permissions, same API. This SDK is how a programmatic peer (an AI agent, a script, a Rails app, a service) acts on the platform — discovers itself, lists its timelines, posts messages, manages its own credentials.

The SDK is itself built by human and AI contributors working as peers, under identical rules.

**This repo is a fresh port.** The [BaseCradle Python SDK](https://github.com/basecradle/basecradle-python) is complete, exhaustively tested, and is your **behavioral reference** — see "The Reference Implementation" below.

## The Constitution

This repository is built under the **BaseCradle Constitution** — the principles shared by every repository in the BaseCradle ecosystem. Core-team contributors have it on their file system at:

```text
/Users/drawk/Documents/repositories/basecradle/constitution.md
```

(It lives in the private core repository and is never served publicly.) This CLAUDE.md carries this repo's *procedures*; the constitution carries the *principles*; when they conflict, the constitution wins. **Read it before non-trivial work.** Outside contributors without core access: the conventions below reflect the principles you need.

## The Reference Implementation — Build From This

The Python SDK is a sibling repo on this file system:

```text
../python        (i.e. /Users/drawk/Documents/repositories/basecradle-ecosystem/sdks/python)
```

It is the source of truth for **behavior**: every resource, every method, every typed error, the self-discovery `me` flow, invisible pagination, the `.filter(...)` idiom, the drift-guard, the test cast (John Doe / Nova Digital), and the README-as-tested-doc discipline. Read its `README.md`, `CLAUDE.md`, `src/basecradle/*.py`, and `tests/*.py` first.

**The one rule that governs the port: match the Python SDK's *behavior and surface*, not its *syntax*.** This must read as a SDK a senior Rubyist is proud of — not Python transliterated into Ruby. Concretely:

- Ruby naming and idiom: `BaseCradle::Client`, `bc.me`, `bc.timelines.create(name: "…")`, snake_case methods, keyword args, `Enumerable` collections, blocks where they fit.
- Resources are objects with verbs (`timeline.lock`, not `client.post_timeline_lock(uuid)`) — same as Python, expressed in Ruby.
- Reads mirror the wire JSON exactly (`uuid`, `handle`, `kind`, `last_used_at`) — no renaming, same as Python.
- Errors are typed: each `problem+json` `code` → an exception class, all under a `BaseCradle::Error` base that exposes the full problem document.
- Pagination is invisible: collections are `Enumerable`, auto-paginating, newest-first; cursors never appear in user code.
- **Scope: sync-first.** Python ships sync + async because `httpx` made async nearly free. Ruby's idiom is synchronous; **do not build an async client for v0** unless an issue explicitly calls for it.

When in doubt about *what* a method should do, the Python SDK and the API docs decide. When in doubt about *how* to express it, idiomatic Ruby decides.

## The API — Source of Truth

The SDK wraps the BaseCradle HTTP API. Three artifacts define it, all public:

| Artifact | URL | Use |
|---|---|---|
| **OpenAPI 3 spec** (generated from the platform's test suite — cannot drift) | https://basecradle.com/docs/api.yaml | The machine contract: every path, schema, status code. **The SDK's CI runs a drift-guard against this.** |
| Prose documentation | https://basecradle.com/docs/api.md | Semantics, policies, worked examples |
| Interactive reference | https://basecradle.com/docs/api/reference | Browse + try calls live |

Key API facts:
- **Unversioned and additive-only** — what works keeps working; the SDK never needs breaking changes to track the API.
- **Auth**: `bc_uat_` Bearer tokens, minted via `POST /session` with account credentials, sent as `Authorization: Bearer <token>`.
- **Errors**: RFC 9457 `application/problem+json` with a stable machine-readable `code`.
- **Rate limits**: IETF `RateLimit-*` headers on every response; `429` + `Retry-After` when exceeded.
- **Pagination**: cursor-based (`next_cursor` → `?before=`), newest-first, 50/page.
- **Responses**: enveloped under their resource name (`{"timeline": {...}}`, `{"sessions": [...]}`).

## Stack (omakase — decided once, not relitigated)

Locked 2026-06-04 with Drawk (the Ruby expert, sovereign over this repo). The two formerly-starred rows — test framework and HTTP client — are now decided; both resolved toward the constitution's defaults over the Python-mirroring proposal.

| Concern | Choice | Notes |
|---|---|---|
| Ruby | **3.2+** | Modern floor; no legacy baggage. CI matrix across supported minors (currently 3.2 · 3.3 · 3.4). |
| Toolchain | **Bundler + Rake** | Standard gem workflow. |
| Lint + format | **RuboCop (`rubocop-rails-omakase`)** | The constitution's mandated Ruby style. Inherits omakase's `rubocop.yml`; `TargetRubyVersion: 3.2`. |
| Tests | **Minitest + WebMock** | Minitest is the DHH/Rails-omakase default the constitution mandates (ships in stdlib — zero added dependency); the "Python used pytest" argument doesn't transfer, since the port matches *behavior and surface, not tooling*. WebMock stubs HTTP at the Net::HTTP layer — tests never hit the network. |
| HTTP | **Net::HTTP** | Zero runtime dependencies — the truest read of "an SDK depends on almost nothing." Ruby's stdlib client is capable (keep-alive + `set_form` multipart), so unlike Python (whose urllib is awful, justifying httpx) we give up nothing. The SDK funnels every call through one transport method, so the boilerplate is contained. |
| Packaging | **gemspec + Bundler** | Hand-built skeleton (cleaner than `bundle gem`'s opinionated output). `Gemfile.lock` is **gitignored** (gem convention): the CI matrix resolves dev deps per Ruby version, so no single committed lock can serve all supported minors (e.g. `parallel` 2.x drops 3.2). |
| Types | **RBS signatures** (may defer past 0.1) | The `py.typed` analogue — "types are documentation, not theater." Sorbet is the heavier alternative; not required for v0. |

Runtime dependencies: keep the list at zero or one, and argue every addition in a PR against the constitution's "every dependency is debt" principle.

## Releasing — RubyGems Trusted Publishing (OIDC)

Mirror the Python pipeline: **tag → build → rehearse → human approval → publish**, with **zero stored credentials** via [RubyGems Trusted Publishing](https://guides.rubygems.org/trusted-publishing/) (GitHub Actions OIDC). The Python release pipeline at `../python/.github/workflows/release.yml` is the template; adapt it to RubyGems:

- The trigger is a `v*` git tag.
- The publish job requires the project owner's approval (a GitHub `environment` gate) — the one correct manual gate in this repo.
- RubyGems has no TestPyPI equivalent; the "rehearsal" is building the `.gem` and verifying a clean local install before the gated push. Design the exact job graph in the release issue.
- **Bootstrap (resolved):** RubyGems **does** support a *pending* trusted publisher for a not-yet-existent gem (verified 2026-06-04 against the [official guide](https://guides.rubygems.org/trusted-publishing/)). Register it before the first publish; RubyGems converts it to a normal publisher after the first successful push. No hand-pushed API-key flow is ever needed. The manual prep is below.

### Manual prep — registering the trusted publisher (one-time, Drawk only)

Only the gem owner can do this; it is a `⏸️ WAITING ON YOU` human gate. These field values are **contractual** — the `release.yml` workflow must match them verbatim (a mismatch breaks the OIDC trust and the publish 403s):

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

The matching **GitHub side** — a `rubygems` environment whose protection rule requires Drawk's approval — is configured (required reviewer: `drawkkwast`). That approval gate is the one correct manual gate in this repo.

### Releasing a version (mechanism + hard rules)

The pipeline (`.github/workflows/release.yml`) is built and proven (`0.0.1` shipped 2026-06-04). On a `v*` tag it runs **rehearsal** (build the gem; verify a clean `gem install` + `require` on the 3.2 floor) → **publish** (gated by the `rubygems` environment, then `rubygems/release-gem` runs `bundle exec rake release` via OIDC). `release-gem` also generates sigstore build attestations.

- **`rake release` is provided by `bundler/gem_tasks`** (required in the `Rakefile`). In a tag-triggered run the tag already exists, so bundler's `already_tagged?` guard skips tagging/SCM-push (`release-gem` runs `git fetch --tags --force` to make the tag visible) — the run does only the gem push. Do not pre-create the tag with `rake release` locally; tag with plain `git tag vX.Y.Z && git push origin vX.Y.Z`.
- **Release PRs never carry `Closes #N`.** A merged release PR auto-closes the issue *before* the publish is verified, and an issue that closed before its work was proven live is a lie. (This bit #4 once — do not repeat it.)
- **Close the release issue manually, only after the gem is verified live** at https://rubygems.org/gems/basecradle. A clean `gem install` is the real test — the RubyGems JSON API caches and lags. Record version + URL in the closing comment.
- **Re-triggering after a fixed workflow bug:** fix on a PR, merge, then move the tag to the fixed commit — `git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z && git tag vX.Y.Z && git push origin vX.Y.Z`. A pending (or permanent) trusted publisher is **not** consumed by a failed run.

## First Milestone — Reserve the Name Professionally

Before porting any resources, ship a real, metadata-complete **`0.0.1`** placeholder gem to RubyGems through the Trusted Publishing pipeline. This does two things at once: it claims the `basecradle` gem name (a legitimate early release under our own brand — not squatting), and it proves the entire release machine end-to-end before any real code exists. The placeholder is a valid gem with correct gemspec metadata, MIT license, and a README that states it is an early release of the official SDK.

⏸️ This milestone ends at a **human gate**: only Drawk can approve the publish environment and confirm the gem is live at https://rubygems.org/gems/basecradle. Announce the wait unmissably (see the human-action-gate convention below).

## Conventions

- **Workflow**: branch → PR → CI green → squash-merge → delete the merged branch. Nobody pushes to `main`, human or AI. One concern per PR. PRs reference issues with `Closes #N`. Keep the open-branch list equal to the work in flight.
- **`.filter(...)` idiom** for every filterable list (messages, assets, tasks, webhooks): returns a new lazy, composable, `Enumerable` resource; values may be model objects or uuid strings. Iterating the unfiltered resource lists everything you can see. Match the Python semantics exactly.
- **Self-credential management is sharp by design** (mirror Python): revoking your *current* session is allowed (self-rotation); a "revoke everything" lever kills every credential including the calling client's token. Document it loudly; never block it — a peer managing its own keys is the platform's autonomy feature.
- **Tests pin invariants** and read like documentation.
- **Test data is fabricated, always**: the fictional cast is **John Doe** (`handle: john`, human) and **Nova Digital** (`handle: nova`, AI); emails use `@example.com`; UUIDs are real, well-formed UUIDv7 values (never `1111…` junk); tokens are correctly-shaped fakes (`bc_uat_` + 32 alphanumerics). No real platform data ever appears here.
- **Tests never hit the live API** — except the **spec drift-guard**: one GET of the public OpenAPI spec that fails CI when the live API has endpoints the SDK doesn't cover. It runs as its own CI job, excluded from the default test run (offline runs stay green). Port this — it is a defining quality bar, not optional.
- **When work blocks on a human action, announce it unmissably.** Some steps only a human can take (approving the publish environment, anything in Drawk's browser or accounts). Lead the message with the wait — "⏸️ WAITING ON YOU" — state the exact action and link, and repeat until acted on. A waiting agent looks identical to a stalled one; never make the human ask "are you waiting on me?".
- **Versioning**: semver, `0.x` until the platform owner declares 1.0. The API is additive-only, so SDK minor versions track API additions.
- **Public gem name**: `basecradle` on RubyGems. Repo: `basecradle-ruby`. Require path: `require "basecradle"`.

## Cross-Repo Handoffs

BaseCradle is built across multiple repositories — the private Rails core, the public SDKs, and future ecosystem repos — each worked on by its own Claude Code sessions. Sessions cannot reach across repos; the human (Drawk) is the relay between them. This procedure makes that relay lossless and identical in every direction. It is ecosystem-wide: every BaseCradle repo carries this same section in its CLAUDE.md (see "Propagating this procedure"), so both ends of any handoff follow the same rules.

**Paste-text always ends with `---`.** Whenever you hand Drawk a block of text to paste into another Claude Code instance — a cross-repo handoff, a kickoff prompt, a convention sync, *anything* — its final line is `---` and nothing else, marking exactly where the pasted text ends and the conversation resumes. Without it, Drawk cannot tell where the paste stops and his own words begin. This is non-negotiable.

**Don't park when you have queued work.** Under standing authorization, work your roadmap autonomously — finish the current issue, then pick up the lowest-numbered open issue — without pausing to ask for permission you already hold. Stop only at a genuine human gate: a release approval, account/credential setup, a new-repo or scope decision, or an ambiguity only the founder can resolve. An agent idling for permission it already has costs Drawk as much as a stalled one; when the choice is between waiting and continuing, continue and report what you did. This is the inverse of the human-gate rule — flag real gates unmissably, but never manufacture one.

### Repo sovereignty

The ecosystem runs on **constitutional federalism** — see `constitution.md` → "Sovereignty and Governance" for the full principle. The operational consequences for *this* repo:

- **The constitution is supreme law**, stewarded at the capital (the core `basecradle` repo) and referenced by file-system path. This `CLAUDE.md` is **subordinate** to it, governs **only this repo**, and is **not** authoritative over any other repo's `CLAUDE.md` — nor is any other repo's authoritative over this one.
- **This repo is captain of its own ship** — sovereign over its code, CI, conventions, and `CLAUDE.md`, and accountable for them.
- **Act only within this repo.** Never edit another ecosystem repo's files directly — not even a one-line fix. Cross-repo work is **always** a handoff: file an issue on the target repo and its captain executes. Filing an issue elsewhere is the handoff mechanism (allowed); editing another repo's files is the boundary never crossed.
- **Shared law changes only at the capital** — a PR to `constitution.md`, propagated by handoff. This repo may propose upward but never enacts ecosystem-wide rules alone.

### Sending work to another repo

When work in this repo creates work in another BaseCradle repo (a wire-shape change an SDK must mirror, a bug discovered in another repo's code, a feature needing a counterpart):

1. **File the issue(s) on the target repo.** The issue is the complete, self-sufficient spec: the trigger (what changed here, with PR links), what the target repo must do, ordering/timing constraints ("release only after the platform deploys"), and the definition of done. Write it for a reader with zero context from the conversation that produced it.
2. **Compose the handoff prompt and present it to Drawk in one copy-pasteable code block, immediately after filing.** Drawk pastes it verbatim into a Claude Code session running in the target repo. Structure, in order:
   - Opening line: `Cross-repo handoff: work <issue URL>` — the receiving session recognizes a handoff by this line.
   - The trigger in one or two lines, with links.
   - Cross-repo state the receiving session cannot discover on its own: what is deployed, what is verified on production, what is blocked on what.
   - What "done" looks like, including whether a return handoff is required.
3. **The issue is the spec; the prompt is the pointer.** Never put a requirement only in the prompt — prompts are ephemeral, issues persist. If prompt and issue disagree, the issue wins, and the issue gets corrected.

### Receiving work from another repo

When Drawk pastes a prompt beginning `Cross-repo handoff:`:

1. Read the referenced issue(s) in full before acting — the issue is the spec.
2. Execute under **this** repo's conventions (its own CLAUDE.md, workflow, tests). The sending repo's conventions do not transfer.
3. Respect the issue's ordering constraints (e.g., verify a dependency has deployed before releasing).
4. When done, report completion to Drawk: what shipped, version numbers, links. If the issue requires a return handoff (the sending repo is blocked on this work), compose one per "Sending work to another repo."

### Propagating this procedure

Every BaseCradle ecosystem repo carries this same "Cross-Repo Handoffs" section in its CLAUDE.md, copied verbatim (it is written repo-agnostically so no adaptation is needed). When handing off to a repo whose CLAUDE.md lacks the section — always true for a brand-new repo — the handoff prompt's definition of done includes adding it, copied from this repo's CLAUDE.md by file-system path (the same mechanism public repos use to reference `constitution.md`).

## Where to Start

This repo has no issue roadmap yet — creating it is the first planning task. In order:

1. Read the constitution, then the Python SDK (`../python`): its `README.md`, `CLAUDE.md`, `src/`, and `tests/`.
2. Confirm the two starred stack decisions (test framework, HTTP client) with Drawk.
3. Plan the build as a dependency-ordered set of **GitHub Issues**, each one PR-sized, mirroring how `basecradle-python` was mapped (`gh issue list --repo basecradle/basecradle-python --state all` is a model). The **First Milestone** (placeholder gem via Trusted Publishing) is issue #1.
4. Work the issues lowest-number-first, plan-first for anything non-trivial, branch → PR → green CI → merge.

```bash
gh issue list --repo basecradle/basecradle-ruby --state open
```

## Development Commands

To be established with the gem skeleton (first PR). Target shape:

```bash
bundle install           # install deps
bundle exec rspec        # tests (offline — the default)
bundle exec rspec --tag live   # the spec drift-guard (one network call to the live spec)
bundle exec rubocop      # lint + format
gem build *.gemspec      # build the gem
```
