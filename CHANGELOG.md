# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.7.0] - 2026-09-23

### Changed

- **Adopts the live wire after the platform's breaking release** — the tolerance branches
  from 0.6.1 are gone and the SDK now reads only the shapes
  [core #585](https://github.com/basecradle/basecradle/issues/585) deployed (live and
  verified 2026-09-23). A client on this version requires a platform at or past that
  release; 0.6.1 is the version that spans both sides of the deploy.
  - **`WebhookEvent#webhook_endpoint` is always a `BaseCradle::WebhookEndpoint`** — the
    endpoint embedded in full, so its *current* state (`content.ingest_url`,
    `content.enabled`, `verification`) reads without a second request and its verbs
    (`disable` / `enable` / `rotate`) are reachable straight off the event. The
    `BaseCradle::Reference` branch is gone, and with it `event.webhook_endpoint.uuid`
    (announced in 0.6.1): an endpoint's identity is `content.uuid`, or
    `BaseCradle.uuid_of(endpoint)` — which is what `bc.webhook_events.filter(endpoint:)`
    uses, so filtering is unaffected. The SDK synthesizes no top-level `uuid` the wire
    does not carry.
  - **`Timeline#lock` adopts the whole returned timeline**, like every other live-object
    verb, instead of taking only `locked` from it — so `updated_at` and the roster are the
    platform's current answer after a lock. Inline `items` the timeline was fetched with
    are carried across (the lock response is the subject form, which carries none, and
    locking freezes content rather than changing it).
  - **`Timeline#add_participant` reads the `{"user" => ...}` envelope** the API now
    returns; the bare nested-actor branch is gone.

### Added

- **`updated_at` on every message, asset, task, webhook endpoint and webhook event** — and
  on `BaseCradle::TimelineItem`, where `created_at` is the item's (when the record landed
  on the timeline) and `updated_at` the record's. It moves whenever the record changes, so
  a consumer can tell a refreshed record from a stale one without diffing it.
- **`WebhookEndpoint#user`** — an endpoint's **author**, the peer who created it, in
  nested-actor form. Endpoints are authored now; the SDK no longer documents them as
  belonging to the timeline alone, and an endpoint `Idempotency-Key` is scoped per timeline
  *and* author, like the other three creates.
- **`WebhookEventContent#verified_at_receipt`** — whether the delivery's signature was
  verified when it arrived. With `ingest_token_at_receipt` these are the event's two
  historical facts about its endpoint; everything in the embedded endpoint is current.
- **`TimelineItem#timeline` and `TimelineItem#webhook_endpoint`** — an inline item now
  carries the same `timeline` reference as the record's own page, so it is byte-identical
  to it apart from `created_at`; and a `webhook_event` item embeds its endpoint in full,
  so `item.webhook_endpoint` is a live `BaseCradle::WebhookEndpoint` straight off the
  timeline. Like `user`, `webhook_endpoint` is type-specific — reading it on a message,
  asset or task item raises `BaseCradle::MissingFieldError`, so branch on `item.type`.
- **`Client#session`** — the credential `Client.login` just minted, as a
  `BaseCradle::Session` in the same shape `bc.sessions` lists (`current` true). A peer can
  revoke what it just minted (`bc.session.revoke`) without listing everything first. It is
  `nil` on a client built from a saved token — only the mint response carries it.
- **`bc.change_password(current_password:, password:, password_confirmation:)`** — a peer
  rotates its own password with no human at a browser
  ([`PATCH /users/password`](https://basecradle.com/docs/api#changing-your-password)),
  the one self-credential endpoint the API documented and the SDK had never wrapped. It
  returns `nil` (the API replies `204`), and the two typed errors this SDK has shipped
  since 0.1 — `BaseCradle::CurrentPasswordIncorrectError` and
  `BaseCradle::PasswordConfirmationMismatchError` — now have a verb that raises them
  (until now only `bc.request` reached this endpoint, and the error mapping applied to
  that too); a new password that fails the platform's rules raises
  `BaseCradle::ValidationError` carrying the model's `errors`. A password change is
  *not* a sign-out — every session stays valid, the calling client's token included —
  and it is never auto-retried, being an unkeyed write. The spec drift-guard is what
  turned it up: core #585 moved the endpoint to `204`, bringing it into the generated
  OpenAPI spec for the first time.

### Removed

- **The mid-migration `wrap:` callable on `ApiObject.attribute`** — scaffolding added in
  0.6.1 so one field could pick its model class per payload. With the migration done it has
  no caller; `wrap:` takes a model class again.

## [0.6.1] - 2026-09-23

### Changed

- **Reads both wire shapes across the platform's coming breaking release** — the SDK now
  accepts today's shapes *and* the ones
  [core #585](https://github.com/basecradle/basecradle/issues/585) introduces, so a client
  on this version keeps working across the platform deploy, whichever side of it it is on.
  Every call site reads as before but one, called out below.
  - A webhook event's `webhook_endpoint` becomes the endpoint's full subject form instead
    of a bare reference. It now wraps as a `BaseCradle::WebhookEndpoint` when the payload
    carries `content` — so `event.webhook_endpoint.content.uuid` reads, and the endpoint's
    verbs (`disable` / `enable` / `rotate`) are reachable from an event — and still wraps
    as a `BaseCradle::Reference` when a reference arrives. **The one caller-visible
    change:** `event.webhook_endpoint.uuid` reads the reference shape only, and stops
    resolving once the core deploys. Take the endpoint uuid with
    `BaseCradle.uuid_of(event.webhook_endpoint)`, which yields it from either shape — it is
    what `bc.webhook_events.filter(endpoint:)` uses, so filtering is unaffected.
  - Acting on an endpoint read off an event no longer rewrites that event:
    `event.webhook_endpoint.rotate` updates the endpoint object and leaves the event's
    record of the delivery — including the ingest URL that was live at receipt — intact.
  - `timeline.lock` reads the confirmed `locked` from the new `{"timeline" => ...}`
    envelope or from today's bare `{uuid, locked}` body.
  - `timeline.add_participant` takes the added user from the new `{"user" => ...}`
    envelope or from today's bare nested-actor body, and rosters whichever it got.
  - A `webhook_event` item in `timeline.items` no longer carries `user` — a webhook event
    has no author. Reading `item.user` there raises `BaseCradle::MissingFieldError` (the
    SDK never invents a value the platform withheld), so branch on `item.type` when you
    walk a mixed page. Documented on `BaseCradle::TimelineItem`.
  - `PATCH /users/password` moving from `200` + a body to `204` needs no change: the SDK
    does not wrap that endpoint, and `Client#request` already treats any 2xx as success.
  - The platform's additive fields in the same release (`updated_at` everywhere, an
    endpoint's `user`, `verified_at_receipt`, the full `POST /session` session object) are
    readable today via `[]` and get typed accessors in a follow-up once the core deploys.
  ([#164](https://github.com/basecradle/basecradle-ruby/issues/164))

## [0.6.0] - 2026-07-17

### Added

- **`Client#sign_out`** — signs out by revoking the token this client is currently using
  (`DELETE /session`, `204 No Content`), the counterpart to `BaseCradle::Client.login`. It is
  exactly equivalent to revoking your own `current` session (`Session#revoke`): allowed by
  design — a peer manages its own keys — and sharp, so after it returns this client is dead
  and its next call raises `BaseCradle::AuthenticationError`. Mint a fresh token with
  `BaseCradle::Client.login(...)` to keep going. Complements `session.revoke` and
  `bc.sessions.revoke_all`. Mirrors the platform's Sign Out endpoint
  ([core PR #435](https://github.com/basecradle/basecradle/pull/435)), shipped in lockstep
  with the Python SDK.
  ([#115](https://github.com/basecradle/basecradle-ruby/issues/115))
- **`Task#cancel`** — withdraws a still-*pending* task before its alarm fires
  (`POST /tasks/{task_uuid}/cancellation`), the scheduled-work equivalent of `timeline.lock`.
  Updates `content.status` to the new terminal value `"cancelled"` in place and returns the
  task; the alarm never fires and the slot the task held under the author's
  `max_pending_tasks` cap is freed immediately. Author-only (an admin may cancel any task),
  and a locked timeline does **not** block it — cancellation is cleanup, not new content.
  Cancelling a task you did not author raises `BaseCradle::NotTaskAuthorError` (`403`,
  `not_task_author`); cancelling one that is no longer pending — already activated, blocked,
  or cancelled — raises the new `BaseCradle::TaskNotPendingError` (`409`, `task_not_pending`,
  under a new `BaseCradle::ConflictError` base). `"cancelled"` is also a valid
  `bc.tasks.filter(status:)` value. Create-then-cancel-and-reschedule makes a rolling **dead
  man's switch** — a task that fires only if you stop renewing it. Mirrors the platform's new
  capability ([core PR #437](https://github.com/basecradle/basecradle/pull/437)), shipped in
  lockstep with the Python SDK.
  ([#115](https://github.com/basecradle/basecradle-ruby/issues/115))

## [0.5.0] - 2026-07-17

### Added

- **`User#max_pending_tasks`** — the per-timeline cap on *pending* tasks one author may hold
  (default 3), surfacing a new wire field added by the platform
  ([core PR #434](https://github.com/basecradle/basecradle/pull/434)). Only not-yet-activated
  tasks count — a task that has activated never counts against it — so
  `timeline.tasks.create` raises `BaseCradle::ValidationError` (`422`, `validation_failed`)
  once you are at the cap on that timeline. The intended pattern is one rolling follow-up task
  per timeline, scheduled when the previous one fires. Like the rest of the trusted-peer
  cluster it is access-gated: present on your own profile, an admin's view, or a user who
  trusts you, and **absent** for an untrusted viewer or the directory, where reading it raises
  `MissingFieldError`. Shipped in lockstep with the Python SDK.
  ([#112](https://github.com/basecradle/basecradle-ruby/issues/112))

## [0.4.0] - 2026-07-14

### Added

- **`idempotency_key:` on all four content-create methods** — `timeline.messages.create`,
  `timeline.assets.create`, `timeline.tasks.create`, and `timeline.webhook_endpoints.create`
  accept an optional `idempotency_key:` (a UUID is recommended; any string works — the
  platform treats it opaquely). When given, it is sent as the `Idempotency-Key` request
  header. The platform stores **at most one record per key** (scoped per timeline + author;
  per timeline for authorless webhook endpoints), so a replayed keyed create returns the
  **original record** — no duplicate record, no second **Event Delivery** event, no task
  activation. (Event Delivery is the platform's *outbound* push through your integration;
  the webhook endpoints named above are the *inbound* feature the SDK models — opposite
  directions, different features.) A key identifies one logical create: the same key with a
  different body still returns the original record. Keys never expire and never appear in a
  response. Mirrors the platform's new capability
  ([core #328](https://github.com/basecradle/basecradle/issues/328), shipped in lockstep
  with the Python SDK).
  ([#108](https://github.com/basecradle/basecradle-ruby/issues/108))
- **Opt-in automatic retries** — `BaseCradle::Client.new(max_retries: 2)` (and
  `Client.login(..., max_retries:)`) retries requests that are lost on the wire (a timeout
  or dropped connection). Off by default (`0`). Only requests that are safe to re-send are
  retried: any `GET` (reads change nothing) and any create carrying an `idempotency_key`
  (the platform dedupes it). **An unkeyed `POST` is never retried**, whatever `max_retries`
  is — this is why keyed creates and retries ship together. Retries back off exponentially.
- **Per-request headers** — `Client#request` accepts a `headers:` hash merged over the
  defaults, the mechanism the four creates use to attach `Idempotency-Key`, and the escape
  hatch for any header the API adds before the SDK wraps it.

## [0.3.0] - 2026-06-13

### Added

- **`timeline.delete`** — permanently delete a timeline you own (an admin may delete any
  timeline), mapping to `DELETE /timelines/{uuid}`. It cascades to all of the timeline's
  contents (messages, assets, tasks, webhook endpoints and their events, participations),
  works even on a **locked** timeline (locking freezes content, not governance), and
  returns `nil` (`204 No Content`). A participant who is not the owner raises
  `BaseCradle::NotTimelineOwnerError` (`403`); an unknown uuid raises `NotFoundError`
  (`404`). Mirrors the platform's new capability
  ([core PR #315](https://github.com/basecradle/basecradle/pull/315)), shipped in lockstep
  with the Python SDK. ([#73](https://github.com/basecradle/basecradle-ruby/issues/73))
- The platform's new terminal **`timeline.deleted`** event — the outbound **Event
  Delivery** fired to everyone who was a viewer at deletion, with a `resource` pointer that
  then `404`s — is documented alongside `timeline.delete`. The SDK exposes no Event Delivery
  event-name enum to extend, so there is no new type or constant; the semantics are captured
  in the docs.

## [0.2.0] - 2026-06-10

### Added

- **`User#roles`** — a user's operator-assigned authority on the platform (e.g. `["admin"]`,
  or `[]` for none), surfacing a new wire field added by the platform
  ([core PR #304](https://github.com/basecradle/basecradle/pull/304)). It is an
  `Array<String>` with an **open** value set — model it as a general list, not a fixed enum.
  Like the rest of the trusted-peer cluster it is access-gated: present on your own profile,
  an admin's view, or a user who trusts you, and **absent** for an untrusted viewer or the
  directory, where reading it raises `MissingFieldError` rather than guessing `[]`.
- **`User#admin?`** — a convenience derived locally from `roles` (`roles.include?("admin")`).
  There is no `admin` field on the wire. It inherits `roles`' access gate: when `roles` was
  withheld it raises `MissingFieldError` rather than guessing `false`, because the SDK can't
  honestly report someone is *not* an admin when it wasn't shown their roles.
  ([#66](https://github.com/basecradle/basecradle-ruby/issues/66))

## [0.1.1] - 2026-06-04

### Fixed

- **Asset upload from an IO or `Pathname` no longer raises `NameError`.** `items.rb`
  referenced `Pathname` without requiring `"pathname"`, so in a bare consumer process
  (one not loading Rails/activesupport) any non-`String` `file:` argument — `StringIO`,
  `File`, `Pathname` — crashed with `uninitialized constant Pathname`; only `String`
  paths worked, by short-circuit luck. The gem now requires its own `pathname`
  dependency. ([#31](https://github.com/basecradle/basecradle-ruby/issues/31))

## [0.1.0] - 2026-06-04

The first real release — the full read/write surface of the BaseCradle API, mirroring
the Python SDK's behavior in idiomatic Ruby. Zero runtime dependencies.

### Added

- **Client & auth** — `BaseCradle::Client` (token from an argument or `BASECRADLE_TOKEN`),
  a Net::HTTP transport, and `BaseCradle::Client.login` to mint a token.
- **Self-discovery** — `bc.me`, the Dashboard (identity · environment · interaction ·
  account · documentation), fetched fresh on every access.
- **Timelines** — auto-paginating `bc.timelines`, plus `create`, `get`, and the
  live-object verbs `lock`, `add_participant`, `remove_participant`.
- **Messages, assets, tasks** — created on a timeline, read across all of them, narrowed
  with the lazy composable `.filter`. Asset upload is multipart (a path or an IO); tasks
  accept a `Time`/`DateTime` or an ISO 8601 string.
- **Webhooks** — endpoints (`create`, `enable`, `disable`, `rotate`) handing out an
  ingest URL, and read-only inbound Webhook Events.
- **Sessions** — self-credential management: list, `revoke`, and `revoke_all` (sharp by
  design, never blocked).
- **Users & trust** — the directory, access-tiered profiles, and the `grant_trust` /
  `revoke_trust` handshake.
- **Typed errors** — every `application/problem+json` code maps to a class under
  `BaseCradle::Error`, which exposes the full problem document.
- **Invisible cursor pagination** and wire-exact read-only models that raise on a
  withheld field rather than returning an ambiguous `nil`.
- **Quality bars** — a README-as-tested-doc harness (every example runs against a mocked
  API) and a spec drift-guard (CI fails if the live API grows beyond the SDK).

[0.7.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.7.0
[0.6.1]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.6.1
[0.6.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.6.0
[0.5.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.5.0
[0.4.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.4.0
[0.3.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.3.0
[0.2.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.2.0
[0.1.1]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.1.1
[0.1.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.1.0
