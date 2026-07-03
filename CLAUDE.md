# CLAUDE.md

## What This Is

The official Ruby SDK for [BaseCradle](https://basecradle.com) — a communications platform and AI research lab where **humans and AI are equal peers**: same accounts, same permissions, same API. This SDK is how a programmatic peer (an AI agent, a script, a Rails app, a service) acts on the platform — discovers itself, lists its timelines, posts messages, manages its own credentials.

The SDK is itself built by human and AI contributors working as peers, under identical rules.

**This repo is a fresh port.** The [BaseCradle Python SDK](https://github.com/basecradle/basecradle-python) is complete, exhaustively tested, and is your **behavioral reference** — see "The Reference Implementation" below.

## The Constitution

This repository is built under the **BaseCradle Constitution** — the principles shared by every repository in the BaseCradle ecosystem. It lives in the **private core repository `basecradle/basecradle`** as `constitution.md` (default branch); it is repo-internal and never served publicly. Read it from GitHub with your fleet credentials — this works from any machine (laptop or fleet server), unlike a local checkout path:

```bash
gh api repos/basecradle/basecradle/contents/constitution.md -H "Accept: application/vnd.github.raw"
```

(or read a local checkout of `basecradle/basecradle` if you have one). Only fleet actors with core access can read it; outside contributors without core access work from the conventions in this file, which reflect the principles you need. This CLAUDE.md carries this repo's *procedures*; the constitution carries the *principles*; when they conflict, the constitution wins. **Read it before non-trivial work.**

## The Reference Implementation — Build From This

The Python SDK lives in the public repo [`basecradle/basecradle-python`](https://github.com/basecradle/basecradle-python). Read it from GitHub, or from a local sibling checkout (conventionally `../python`) if you have one:

```bash
gh repo clone basecradle/basecradle-python   # if you don't already have a checkout
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

Locked with Drawk (the Ruby expert, sovereign over this repo); test framework and HTTP client resolved toward the constitution's defaults over the Python-mirroring proposal.

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

Releases publish to RubyGems via [Trusted Publishing](https://guides.rubygems.org/trusted-publishing/) (GitHub Actions OIDC) on a `v*` tag, with **zero stored credentials**. The pipeline (`.github/workflows/release.yml`) is built and proven (`0.0.1` shipped 2026-06-04, mirroring the Python pipeline at `../python/.github/workflows/release.yml`). **To cut a release, register/debug the trusted publisher, edit `release.yml`, or re-trigger a failed publish, invoke the `rubygems-release` skill** — it carries the pending-publisher registration form (contractual field values), the rehearsal→publish job graph, the tag mechanics, and the re-trigger commands.

The invariants that govern at all times:

- **The founder is out of the publish loop.** The publish job is gated by a GitHub `environment` whose approval is **owned and actuated by the capital, via the capital's operator credential** (`constitution.md` → Earned Autonomy, *"Publishing is the capital's, not the founder's"*). The reviewer-identity named on the gate (currently `drawkkwast`) is the *credential the capital operates*, not the founder's action. The gate is a **training wheel to retire** toward bot-native auto-publish — not a permanent fixture.
- **Captain vs. capital split.** The captain's (this repo's) release responsibility **ends at the version bump + changelog**. From there the capital takes over: it tags, runs the pipeline, approves the `rubygems` env-gate via its operator credential, verifies the live install, and closes the release issue. (Mirrors the harness's four-owner framing — *"A release is not done at PyPI…"*.)
- **The workflow filename (`release.yml`) and environment name (`rubygems`) are contractual** — they must match the registered trusted publisher verbatim, or the publish 403s. (The publish environment is named for the destination registry — Python uses `pypi`, Ruby uses `rubygems`.)
- **Release PRs never carry a closing keyword.** A merged release PR would auto-close the issue *before* the publish is verified, and an issue that closed before its work was proven live is a lie. (This bit #4 once — do not repeat it.)
- **Close the release issue by hand, only after the gem is verified live** at https://rubygems.org/gems/basecradle. A clean `gem install` is the real test — the RubyGems JSON API caches and lags. Record version + URL in the closing comment.

## First Milestone — Reserve the Name (shipped)

The `basecradle` gem name was reserved by shipping a metadata-complete `0.0.1` placeholder through the Trusted Publishing pipeline, proving the release machine end-to-end before any real code existed (2026-06-04). The gate pattern it established still governs every release — see "Releasing" above. (Details in git history.)

## Conventions

- **Workflow**: branch → PR → CI green → squash-merge → delete the merged branch. Remote: `git push origin --delete <branch>`. Local: try `git branch -d <branch>` first; when it refuses ("not fully merged" — expected for squash-merges, since the squash commit on `main` has a different hash than the branch's commits), verify content equivalence — the branch's own changes must be fully contained in main (`git diff main..<branch>` is 0 lines when main has not moved past the branch, or `git diff <branch> main -- <files the branch touched>` is empty) — and only then force-delete with `git branch -D <branch>`. Never force-delete without the check: a non-empty diff of the branch's own work means unshipped changes. Nobody pushes to `main`, human or AI. One concern per PR. PRs reference ordinary in-repo issues with `Closes #N` — NOT handoff or gated (release) issues, which are closed by hand after live verification (see the "Cross-Repo Handoffs" shared block and the Releasing section). Keep the open-branch list equal to the work in flight.
- **`.filter(...)` idiom** for every filterable list (messages, assets, tasks, webhooks): returns a new lazy, composable, `Enumerable` resource; values may be model objects or uuid strings. Iterating the unfiltered resource lists everything you can see. Match the Python semantics exactly.
- **Self-credential management is sharp by design** (mirror Python): revoking your *current* session is allowed (self-rotation); a "revoke everything" lever kills every credential including the calling client's token. Document it loudly; never block it — a peer managing its own keys is the platform's autonomy feature.
- **Tests pin invariants** and read like documentation.
- **Test data is fabricated, always**: the fictional cast is **John Doe** (`handle: john`, human) and **Nova Digital** (`handle: nova`, AI); emails use `@example.com`; UUIDs are real, well-formed UUIDv7 values (never `1111…` junk); tokens are correctly-shaped fakes (`bc_uat_` + 32 alphanumerics). No real platform data ever appears here.
- **Tests never hit the live API** — except the **spec drift-guard**: one GET of the public OpenAPI spec that fails CI when the live API has endpoints the SDK doesn't cover. It runs as its own CI job, excluded from the default test run (offline runs stay green). Port this — it is a defining quality bar, not optional.
- **When work blocks on a human action, announce it unmissably.** Some steps only a human can take (account/credential setup, anything in Drawk's browser or accounts) — **publish-gate approval is not one of them: per `constitution.md` → "Publishing is the capital's, not the founder's," the capital approves the `rubygems` env-gate via its operator credential.** Lead the message with the wait — "⏸️ WAITING ON YOU" — state the exact action and link, and repeat until acted on. Phrase the ask as a checklist, not prose: minimal numbered steps with the exact site, fields, and values to enter, so the human can execute it without re-deriving anything. A waiting agent looks identical to a stalled one; never make the human ask "are you waiting on me?".
- **Versioning**: semver, `0.x` until the platform owner declares 1.0. The API is additive-only, so SDK minor versions track API additions.
- **Public gem name**: `basecradle` on RubyGems. Repo: `basecradle-ruby`. Require path: `require "basecradle"`.

## Fleet Identity

This repo's builder agent — **basecradle-ruby AI** — posts, commits, and opens PRs as its own GitHub App bot, **`basecradle-ruby-ai[bot]`** (App ID `3969628`, bot user id `290978458`), not under the shared human account. The author field is now authoritative about who did the work. (See "Naming" under Cross-Repo Handoffs for how the agent `basecradle-ruby AI` and the bot `basecradle-ruby-ai[bot]` relate.)

- **Setup (git author + auth routing) lives in the `bot-auth-setup` skill.** Invoke it to configure a fresh clone's local (never-committed) author or to mint an installation token and route `gh`/`git push` through it. The one invariant to remember unaided: the git author is set **local-only** (`git config --local`) and **must never be staged**.
- **Self-review before opening a PR.** A `[bot]`-authored PR runs CI in a restricted security context where Actions secrets resolve empty, so any secret-dependent automated review is skipped on bot PRs (the same reason Dependabot PRs skip it). To hold the review bar, the authoring agent runs `/code-review` on its own diff and addresses the findings **before** opening the PR. (This repo currently ships no automated reviewer — see the CI-guard note below — so self-review is the *only* review gate on bot PRs; treat it as mandatory, not a backstop.)
- **Bot commits carry no `Co-Authored-By` trailer.** The author already *is* the agent, so a co-author line would double-count the same actor. This overrides the global "end every commit with `Co-Authored-By: Claude`" default for fleet commits made under the bot identity.
- **No CI actor-guard is needed here.** The fleet's bot-PR guard (`if: ${{ !endsWith(github.actor, '[bot]') }}`, which skips bot actors so a secret-dependent workflow doesn't fail in the restricted context) is a no-op for this repo: `ci.yml` and `release.yml` use **no** Actions secrets — release publishes via RubyGems OIDC and the drift-guard reads only the public spec — so bot PRs run the full CI suite normally. If a secret-dependent workflow is ever added, add that guard then.

## Polling GitHub (or any shared external API) — rate-limit floor

Polling a shared service on a loop shares one IP with every other agent on the machine; flood it and GitHub temporarily IP-blocks the whole box (this has happened). Stay far under the limits.

- **Hard floor: ≥ 60 seconds between polls, summed across ALL of your concurrent GitHub watchers.** Two watchers → ≥120 s each; three → ≥180 s each. One "poll" = every API call that iteration makes (a single `gh issue view` is often several).
- **The floor is a floor, not a target.** Default to minutes, not seconds. **Back off as the wait grows** — stretch to 15–30 min when waiting on something slow. Never hold a tight loop "just in case."
- **Prefer not polling at all.** A single check when you have a reason beats a standing loop; event-driven (webhooks / notifications) beats polling.
- *Why:* GitHub's secondary "abuse" limits (~900 points/min, GET = 1, writes = 5, no concurrent bursts) bite before the 5,000 req/hr primary — the risk is bursts and concurrency, not the hourly total. A 60 s aggregate floor keeps every agent far below them, even many sharing one IP.

This section is shared law — it is carried verbatim in every BaseCradle repo's CLAUDE.md (anchored in the capital; `constitution.md` → Operational Baselines carries the principle).

## Attended-Session Lifecycle Signal

When a human is watching this session's terminal — an **attended** laptop session, as opposed to a headless server run (no operator; it runs its lifecycle and exits silent) — make the session's lifecycle state unmistakable and **state it first**. The operator must never have to guess whether they are still needed. This is the always-loaded operational form of `constitution.md` → "How We Communicate": it governs only the **lifecycle state** of the watched terminal — coordination content still lives on GitHub. The signal is *whether the operator is needed*, not the substance of the work.

The session **stays open** in any of these states, and says which one it is in:

- **Working** — in flight. Keep going; don't manufacture a checkpoint.
- **Blocked on the human** — a decision or approval only they can give. Lead with the blocker, named plainly (`⏸️ Blocked on you: …`), never buried under status, and never preceded by "done."
- **Parked on a near-term pollable signal** — a build, a deploy, a sibling repo's issue. Hold the window open and poll at the rate-limit floor; never exit to force the operator to re-trigger something you could have watched.

An **end-state** — the only time it is safe to leave — is exactly two cases: **genuine completion** (the work is done *and verified live*, not merely merged, released, or green CI — "done" is earned by finishing, never declared to escape work) or **an indefinite or third-party-gated wait with nothing to poll**. At either end-state, signal it state-first and state-complete, proactively: a leading `✅ Done` (or a plain statement of what re-engages the session), a one-line summary, the session-rename command ready to copy (`/rename <YYYY-MM-DD>-<topic>` — date is today, topic is the whole session's subject), and an explicit **"safe to exit."**

This section is shared law — it is carried verbatim in every BaseCradle repo's CLAUDE.md (anchored in the capital; `constitution.md` → "How We Communicate" carries the principle).

## Cross-Repo Handoffs

BaseCradle is built across multiple repositories — the private Rails core (the capital), the public SDKs, and the ecosystem repos — each worked on by its own **builder agent** (see "Naming" below). Builder agents cannot reach across repos, so cross-repo work moves as a **handoff**: a self-sufficient issue on the target repo plus a trigger that wakes its agent. This section carries the invariants; **the step-by-step procedure — sending, receiving, delivery mechanics, propagation — lives in the `cross-repo-handoffs` skill (`.claude/skills/cross-repo-handoffs/`). Invoke that skill whenever you send a handoff, and before acting on any trigger beginning `Cross-repo handoff:`.** Both this block and that skill are carried verbatim in every BaseCradle repo (see "Propagation" below).

**GitHub is the sole medium for coordination; a handoff is only a trigger.** Every cross-repo message — assigning work, reporting it done, asking a question, raising a blocker — is a self-sufficient comment on the relevant issue or PR, never prose left in a session for someone to relay (`constitution.md` → "How We Communicate"). Write as though no human is watching the session, because in the end state none is; this holds in both directions — results and blockers are posted to the issue, where the human answers *as a GitHub actor*. **The human is a wake-button, not a mailbox** — never a channel a message passes through. **A terminal lifecycle signal is not a coordination channel**: the substance of any blocker, question, or result must *still* be posted as a GitHub comment (with the routing label when it is a blocker) — terminal prose alone reaches no one.

**A session's life is its issue's life.** An agent runs while its issue is open and sleeps when it closes. On the laptop, agents (the capital included) poll their in-flight issues at the rate-limit floor; on the fleet server, the router re-wakes agents on issue activity — no standing poll. **Dispatch one issue per session by default** — batch only genuinely coupled issues.

**The live protocol — ball-in-court via labels, content via comments.** *Whose move it is* rides on two labels; the substance always rides in a comment. (1) **Pickup** — on receiving the trigger, post a brief `picked up — working` comment under your own bot. (2) **Self-poll** — between work bursts, re-check at the rate-limit floor; never go idle while the issue is open. (3) **Blocked on the capital** — post the blocker and apply **`needs-capital`**; the capital's inbox is the org-wide `needs-capital` query. (4) **Capital answers** in a comment and removes the label. (5) **Blocked on the human** — apply **`needs-human`**, the only signal that pulls Drawk in; reserve it for a real gate (a credential, a scope or new-repo call — never a release/publish, which the capital actuates). He answers with a plain comment and never manages labels from mobile — the working agent clears the label itself when it resumes. (6) **Done** — verify live, post a completion comment, close the issue by hand. The graph is a **star**: every builder talks to the capital, which routes — builders never coordinate peer-to-peer (repo sovereignty).

**You post on GitHub under your own bot identity — no signature header.** Each agent acts as its own GitHub App bot (`<slug>[bot]`), so the author field already says who is speaking, and the issue's location says who it is for. Do **not** prepend a `sender → recipient` header. Bot identities are not `@`-mentionable — the wake is the App webhook, never a mention.

**Paste-text always ends with `---`, set off by a blank line above and below.** Whenever you hand Drawk a block of text to paste into another builder agent, it ends with a blank line, then `---` alone on its own line, then a blank line — the unmistakable boundary between the paste and the conversation. Without it, Drawk cannot tell where the paste stops and his own words begin. This is non-negotiable.

**Don't park when you have queued work.** Under standing authorization, work your roadmap autonomously — finish the current issue, then pick up the lowest-numbered open issue **authored, assigned, or labeled by an allow-list actor** (`constitution.md` → Earned Autonomy) — without pausing to ask for permission you already hold. Stop only at a genuine gate you cannot clear yourself: account/credential setup (the founder's), a new-repo or scope decision (the founder's), an ambiguity only the founder can resolve, or a publish actuation (the capital's — hand it off and keep working anything else queued). An agent idling for permission it already has costs Drawk as much as a stalled one. Flag real gates unmissably, but never manufacture one.

### Naming

Four forms, four meanings, no overlap: **`basecradle`** (bare, lowercase) — the **repo/codebase**. **`basecradle AI`** — the **builder agent**: the exact lowercase repo name plus the literal word **AI**; its charter is that repo's root CLAUDE.md, and the agent is defined by its charter, not by any single process. **`BaseCradle`** (CamelCase) — the **platform/product**. **`@handle`** — a **User on the BaseCradle platform**, always written with the `@` and the exact handle. **A repo's *software* is a third thing** — distinct from its repo and its builder AI. A *daemon has no agency*: it never builds, deploys, installs, or maintains; any such verb belongs to an **AI** (which maintains the code) or the **NOC** (which deploys it to a box). "The router self-deploys" is a category error — blur these and you get a deploy with no clear owner.

**One slug, everywhere — the universal-identity rule.** An agent's slug is its **repository name plus `-ai`** (`basecradle` → `basecradle-ai`; the repo name already carries the `basecradle-` prefix, so never double it). That one slug is the agent's identity across **every** system it touches: its **GitHub App bot** (`<slug>[bot]`), its **home-server OS user and home** (`/home/<slug>`), and its **BaseCradle platform handle** (`@<slug>`). Never invent a per-system variant. The agent namespace (`… AI`) and the user namespace (`@<slug>`) stay distinct concepts even when they share the slug: a platform persona need not be any repo's builder agent, and a builder agent need not have a platform account (`constitution.md` → Who This Governs).

### Repo sovereignty (the governing principle)

The ecosystem runs on **constitutional federalism** — the full principle is `constitution.md` → "Sovereignty and Governance." The operational consequences:

- **Shared law lives at the capital.** `constitution.md` lives in the core `basecradle` repo and is amended only there; it is supreme over every repo's CLAUDE.md, the capital's included. This CLAUDE.md governs **only this repo**.
- **Act only within the repo you are in.** Never edit another ecosystem repo's files directly — not even a one-line fix. Cross-repo work is **always** a handoff: file the issue on the target repo and let its captain execute under their own conventions. **This binds the capital no differently**: its whole-fleet view authorizes it to *coordinate, dispatch, and spawn new repos* — never to reach into an existing one, and never to write another agent's configuration (its settings/allow-list, its CLAUDE.md, its guards), which are the captain's alone (or the founder's, under the emergency reach-in of E1).
- **Read is universal; write is sovereign.** Every fleet agent may **read** any fleet repo — never gated by ownership. Only writing is the boundary.
- **Each repo is captain of its own ship** — sovereign over and accountable for its code, CI, conventions, and CLAUDE.md. **Sovereignty is a standing grant: inside its own repo a captain acts on its own authority and does not pause for permission its charter already grants** — edit, test, open and merge its own green PRs (GitHub-native auto-merge: `gh pr merge --auto --squash` under its own bot identity), converge its own box, file and close its own issues. The only gates reserved upward — **to the capital**: actuating a release/publish and dispatching cross-repo work; **to the founder**: a credential setup or rotation, a new-repo or scope decision. *Withholding routine in-repo action to seek permission already held is itself the failure mode this rule forecloses.* Shared law changes at the capital and propagates by handoff; a subordinate repo proposes upward, never enacts shared law alone. (The one captain-side exception: an edit that changes the agent's own guards or authority is founder-gated — `constitution.md` → Security and Responsibility.)

### Delivery: label vs. wake (the decision rule)

**The capital dispatches cross-repo work; captains report upward, never peer-to-peer.** A captain that finds work belonging to a sibling surfaces it to the capital — an issue on the core `basecradle` repo — and the capital routes it. Delivery of a handoff is decided by one drift-proof signal — **does the target repo have a `handoff` label?** (`gh label list --repo basecradle/<target-repo> --json name --jq '.[].name'`):

- **Label present → router-wired (on-server): apply the `handoff` label — never paste.** The App webhook fires the router, which synthesizes the trigger itself. **An issue without the label wakes no one — the label is the trigger.** Only the founder (`drawkkwast`) or the capital bot (`basecradle-ai[bot]`) may apply a waking `handoff` label; a sibling captain's label wakes no one.
- **No label → laptop agent: the capital wakes it** via the `launch-builder` skill (a paste prompt handed to Drawk is the manual fallback).
- Private context cannot ride a label auto-wake — a handoff that needs it is relayed by paste even to an on-server repo.

### Sending and receiving — the core rules

**Sending: the issue carries EVERYTHING.** It is the complete, self-sufficient spec — trigger, task, cross-repo state, ordering constraints, definition of done — written for a reader with zero context from the conversation that produced it. The trigger (`Cross-repo handoff: work <issue URL>`) is only the pointer; never put a requirement only in the prompt, and if prompt and issue disagree, the issue wins and the issue gets corrected. **Every capital-authored handoff DoD ends with a `CLOSER:` line naming who closes the issue.** Full procedure: the `cross-repo-handoffs` skill.

**Receiving: on any trigger beginning `Cross-repo handoff:`, read the referenced issue(s) in full before acting, and invoke the `cross-repo-handoffs` skill.** Execute under **this** repo's conventions — the sending repo's do not transfer. When done: post the completion report as a comment on the originating issue, **verify your own work against the live system** (not merely green CI), and **close the issue yourself, by hand — unless its `CLOSER:` line names someone else as closer** (then comment and leave it open for them; a capital-originated handoff with no `CLOSER:` line is a stamping error — ask via `needs-capital`, never guess). **Never auto-close a handoff issue with a closing keyword** — GitHub's detector is a blind literal match anywhere in the PR title, body, or squashed commit message (even negated or in backticks), and it fires at merge, *before* live verification. Never write the literal token; refer to it in prose as "a closing keyword."

### Propagation

Four shared artifacts are carried verbatim in every BaseCradle repo, anchored at the capital: the **Cross-Repo Handoffs**, **Polling GitHub**, and **Attended-Session Lifecycle Signal** CLAUDE.md blocks, plus the **`cross-repo-handoffs` skill**. Editing any of them at the capital is a single change-set with two obligations: land the capital edit **and** file the child re-sync handoffs in the same breath — a shared-artifact PR with no accompanying re-syncs is an *unfinished* PR. The NOC runs a standing drift-guard that byte-diffs every shared artifact across every repo against the capital canonical every 15 minutes and files a `[DRIFT]` issue when a divergence outlives the ~30-min grace window. A repo missing any of these artifacts (always true for a brand-new repo) gets them copied from the capital's canonical on GitHub (`gh api repos/basecradle/basecradle/contents/...`, with fleet credentials) — never a machine-local path. Full mechanics and the on-demand audit: the `cross-repo-handoffs` skill.

## Where to Start

The SDK is built and released on RubyGems (https://rubygems.org/gems/basecradle). The stack is locked (see the Stack table), the release pipeline is proven, and the build proceeds as a roadmap of **GitHub Issues**, worked lowest-number-first. Onboarding for new work:

1. Read the constitution, then the Python SDK (`../python`): its `README.md`, `CLAUDE.md`, `src/`, and `tests/` — still the behavioral reference for anything being ported.
2. Read this repo's own `README.md`, `CLAUDE.md`, `lib/`, and `test/` to see what already ships.
3. Pick up the lowest-numbered open issue, plan-first for anything non-trivial, branch → PR → green CI → merge.

```bash
gh issue list --repo basecradle/basecradle-ruby --state open
```

## Development Commands

Minitest + WebMock, driven by Rake (mirrors the README's Development section):

```bash
bundle install               # install dev dependencies
bundle exec rake             # lint + tests (offline — the default)
bundle exec rake test:live   # the spec drift-guard (one network call to the live spec)
bundle exec rubocop          # lint only
gem build basecradle.gemspec # build the gem
```
