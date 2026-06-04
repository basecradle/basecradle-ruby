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

## Stack (proposed omakase — confirm with Drawk before locking)

Decided once, not relitigated — but because Drawk is the Ruby expert and this repo is sovereign, the two starred rows below want his explicit blessing before the first PR locks them in.

| Concern | Proposed choice | Notes |
|---|---|---|
| Ruby | **3.2+** | Modern floor; no legacy baggage. CI matrix across supported minors. |
| Toolchain | **Bundler + Rake** | Standard gem workflow. |
| Lint + format | **RuboCop** | Reuse the style from the core Rails app's `.rubocop.yml` where sensible. |
| Tests ★ | **RSpec + WebMock** | RSpec mirrors the ergonomic choice pytest was on the Python side; WebMock is the respx analogue (stubs HTTP, never hits the network). Minitest is the leaner stdlib alternative — Drawk's call. |
| HTTP ★ | **Faraday** *or* **Net::HTTP** | Python's ethos: minimal deps (httpx was the *only* runtime dep). Net::HTTP = zero deps, more boilerplate; Faraday = one dep, idiomatic and pluggable. Drawk's call. |
| Packaging | **gemspec + Bundler** | `bundle gem` skeleton. No legacy. |
| Types | **RBS signatures** (may defer past 0.1) | The `py.typed` analogue — "types are documentation, not theater." Sorbet is the heavier alternative; not required for v0. |

Runtime dependencies: keep the list at zero or one, and argue every addition in a PR against the constitution's "every dependency is debt" principle.

## Releasing — RubyGems Trusted Publishing (OIDC)

Mirror the Python pipeline: **tag → build → rehearse → human approval → publish**, with **zero stored credentials** via [RubyGems Trusted Publishing](https://guides.rubygems.org/trusted-publishing/) (GitHub Actions OIDC). The Python release pipeline at `../python/.github/workflows/release.yml` is the template; adapt it to RubyGems:

- The trigger is a `v*` git tag.
- The publish job requires the project owner's approval (a GitHub `environment` gate) — the one correct manual gate in this repo.
- RubyGems has no TestPyPI equivalent; the "rehearsal" is building the `.gem` and verifying a clean local install before the gated push. Design the exact job graph in the release issue.
- **Bootstrap note:** if RubyGems does not support a *pending* trusted publisher for a not-yet-existent gem, the gem name is claimed by one initial publish, after which Trusted Publishing is configured for all future releases. Verify which path RubyGems supports and record it in the release issue. Either path is fully professional; do **not** fall back to a hand-pushed API-key flow.

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
