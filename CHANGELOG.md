# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

One deliberate departure from that format: this changelog keeps **no `Unreleased`
section**. The newest heading is always the version `lib/basecradle/version.rb` builds —
a release writes its entry and its version in the same PR — and `test/changelog_test.rb`
fails CI if the two ever disagree.

## [0.11.0] - 2026-10-10

### Added

- **Contact messages and notes, the platform's first admin-only surface**
  ([#229](https://github.com/basecradle/basecradle-ruby/issues/229), mirroring
  basecradle#663). All six new operations are covered:
  - `bc.contact_messages`: newest first and auto-paginating, narrowed with
    `.filter(status: "received" | "closed" | "spam")`, and `.get(uuid)` for one record.
  - `contact_message.update_status(status)`: sets the triage verdict and updates the
    object in place.
  - `contact_message.add_note(body:)`: returns the new `BaseCradle::Note`.
  - `bc.notes` (every note, newest first) and `bc.notes.get(uuid)`.

  A `ContactMessage` is a flat record. It embeds its notes in full, its `user` is `nil`
  for a visitor without an account, and `data` (the vendors' slots) is the platform's
  plain `Hash`, so the vendors are not modeled. A `Note` has the same shape everywhere
  it appears, and its `notable` names its subject's `type` and `uuid`.
- **`BaseCradle::NotAnAdminError`** (a `ForbiddenError`) for the new `not_an_admin`
  code. Every one of the six operations raises it for a caller who is not an admin.
- **`bc.me.admin`**, the Dashboard's admin-only sixth section (`contact_messages_url`,
  `notes_url`, `guide_url`). It is present only for an admin. Reading it as anyone else
  raises `MissingFieldError`, like any other withheld field.
- **`BaseCradle::RequestHeaders`**, the shared class behind a recorded request's
  headers. `WebhookEventHeaders` now subclasses it, with no change to behavior or
  render. A contact message's `headers` is the new `ContactMessageHeaders`, which follows
  the same rules: case-insensitive lookup, and a render that shows header names but
  never their values. A visitor's request headers can carry that visitor's own
  credentials, just as a webhook sender's can.

### Note

- **0.10.4 was never published.** Its version and changelog entry merged, but it was
  never tagged, so its changes reach RubyGems for the first time in this release.

## [0.10.4] - 2026-09-30

### Changed

- **The names-only render rule is one module, and a reflective test now asks it of every
  class** ([#212](https://github.com/basecradle/basecradle-ruby/issues/212)). Every
  renderable object in this SDK prints its field *names* and never its field values —
  that is what keeps a `bc_uat_` token, an inbound sender's `Authorization` header and an
  endpoint's `ingest_url` out of logs, REPL transcripts and exception messages. Until now
  the rule was three hand-rolled copies of the same three methods with nothing asking the
  question of a fourth class, which is precisely how 0.10.2's leak arrived:
  `WebhookEventHeaders` was added as a `Hash` descendant, `Hash` brought its own render,
  every header value printed, and the suite stayed green. `BaseCradle::RendersNamesOnly`
  now supplies `inspect`, `to_s` and `pretty_print` to `ApiObject`, `Client` and
  `WebhookEventHeaders`, and `test/basecradle/rendering_test.rb` walks the SDK's own
  constants to assert every renderable class gets all three from it. **No existing render
  changed**, `Client`'s included — this is the same output from one place instead of
  three, plus the guard. No leak was found; this closes the shape of the last one.
- **A record interpolates as its field names instead of a heap address.** `ApiObject` had
  no `to_s` or `pretty_print` of its own, so `"#{message}"` and `puts message` gave
  `#<BaseCradle::Message:0x000074385e23d470>`. They now give
  `#<BaseCradle::Message body, uuid>`, the same string `inspect` and `pp` already gave.
  Nothing was leaking — a heap address is not a value — but two of the three doors on the
  SDK's most common object belonged to `Kernel` rather than to the rule.
### Fixed

- **A record with mixed-type keys no longer raises from its own render.** `ApiObject`
  sorted its field names with `sort`, which refuses `comparison of Symbol with String
  failed` — reachable because the README documents rebuilding a model from a cached
  record, and a cache layer that symbolizes some keys hands back exactly that. It was one
  raising door before and would have been three after the change above, so it now sorts
  by the names' string form, as `WebhookEventHeaders` always has.
- **A record with no fields renders as `#<BaseCradle::Message>`**, not
  `#<BaseCradle::Message >` with a dangling space. Reachable whenever the API sends a
  nested content object as `{}`.

- **The ActiveSupport harness renders the class 0.10.2 secured.** The child-process probe
  excluded `Hash` descendants, which was a true statement about *serialization* (a
  delivery's headers are a record and serialize) applied to a render question it does not
  answer — so the one class that fix was written for was never rendered under real
  ActiveSupport by the harness that exists for that. There is now a records bucket,
  covered reflectively against every `Hash` descendant the SDK defines, asserting both
  halves: the render stays names-only through all three doors, and the record still
  serializes.

## [0.10.3] - 2026-09-30

### Security

- **`Marshal.dump` and `to_yaml` no longer emit a `Client`'s token**
  ([#205](https://github.com/basecradle/basecradle-ruby/issues/205)). 0.10.1 shut the
  JSON door on a client; `Marshal` and Psych walk instance variables directly, consult no
  `as_json`, and need no ActiveSupport to do it — so both still wrote the raw `bc_uat_`
  credential into their output. They are the worse pair, because they are what puts a
  token *at rest*: ActiveSupport's cache stores marshal what you write, so
  `Rails.cache.write("bc", bc)` landed it in Redis, memcached or a file store; a
  Marshal-backed session landed it in the session; Delayed::Job YAMLs its handler into
  the database. (Queue backends that serialize arguments as **JSON** — ActiveJob and
  Sidekiq among them — go through `to_json`, and so were already closed in 0.10.1.)
  `Marshal.dump(bc)`, `bc.to_yaml`,
  `YAML.dump(conn: bc)` and the `Marshal.load(Marshal.dump(bc))` deep-copy idiom now all
  raise `BaseCradle::NotSerializableError`, the same typed error with the same message
  the JSON door already raised. Long-standing and latent; no token is known to have been
  emitted.
- **The collection door was the wider one, not the narrower one.** Through JSON, a
  collection never reached the token — ActiveSupport's `Enumerable#as_json` shadows
  `Object#as_json`, so `bc.messages.to_json` serialized fetched records, never the client
  held in an ivar. `Marshal` and Psych have no such shadow, so
  **`Marshal.dump(bc.messages)` reached the credential where `bc.messages.to_json` never
  did** — and a query is the likelier of the two to be handed to a cache. Every lazy
  collection (`bc.timelines`, `bc.messages`, `timeline.tasks`, any `.filter(...)`, the
  `Paginator` behind them) now refuses through all four doors; the refusals are on the
  shared `NotSerializable` mixin, so a resource added later is covered by construction.
  **`.to_a` is only half the remedy for a dumper** — the array it hands back is full of
  models that each hold the client, so `Marshal.dump(bc.messages.to_a)` lands back on the
  same error. Dump `bc.messages.to_a.map(&:to_h)`, which the refusal now says.
- **Anything holding a client refuses too — models included, and that is the fix.** Both
  walkers recurse, so `Marshal.dump(message)` and `message.to_yaml` reached the client's
  token where `message.to_json` (which serializes the wire record) never did. They now
  raise, naming `BaseCradle::Client` as what was reached. **If you cache or enqueue
  models, cache the record instead** — `message.to_h` is the wire `Hash`, holds no
  client, and marshals exactly as it always did; rebuild with
  `BaseCradle::Message.new(record, client: bc)` when you need the verbs back. Nothing
  else changed: `to_json`, `as_json`, `to_h`, `inspect`, every field reader and
  `dup`/`clone` (which do not go through `Marshal`) are untouched. This matches the
  Python SDK, whose `__reduce__` refusal says the same thing — *“Nothing holding a client
  can be serialized either … copy the record's data instead.”*

### Known limitation

- **YAML reaches the `Enumerator` escape that 0.10.1 documented for JSON, on plain
  Ruby.** Every refusal here is on this SDK's own objects; an `Enumerator` you build from
  a collection (`bc.messages.each`, `bc.messages.lazy`) is a plain Ruby object this SDK
  does not own and may not patch. Psych iterates one to dump it — with **no
  ActiveSupport required**, where the `to_json` version is inert without it — so
  `bc.messages.each.to_yaml` fires the page-by-page GET loop and *then* raises
  `NotSerializableError` on the first record, which holds the client: the requests are
  spent and no document comes out. `Marshal` is the exception — Ruby itself refuses to
  dump an `Enumerator` at all. No token is exposed through any of them. Call `.first(n)`
  or `.to_a` before a renderer, and `.map(&:to_h)` too before a dumper.
- **Four doors is every hook Ruby gives a library**, not every way bytes can be made. A
  serializer that reads instance variables directly rather than through `as_json`,
  `to_json`, `marshal_dump` or `encode_with` is outside what this SDK can intercept.
  Keep a client out of one.

### Migrating

Nothing to change unless you `Marshal.dump` or `to_yaml` something that holds a client.
If you do:

- **Caching or enqueuing a model** — `Rails.cache.write(key, message)`,
  `Rails.cache.fetch(key) { bc.messages.get(id) }` — now raises
  `BaseCradle::NotSerializableError` where it used to write your token to the store.
  Cache `message.to_h`, the wire `Hash`, and rebuild with
  `BaseCradle::Message.new(record, client: bc)` if you need the verbs back.
- **Caching or enqueuing a client or a collection** — serialize nothing; build a client
  where you need one (`BaseCradle::Client.new(token)`), moving the token only through
  whatever you already trust with secrets. For a collection, `.to_a` / `.first(n)` is
  enough for JSON but **not** for a dumper — use `bc.messages.to_a.map(&:to_h)`, since
  the models in that array each hold the client.
- **Deep-copying with `Marshal.load(Marshal.dump(x))`** — refuses at the dump for the
  same objects. `dup` and `clone` do not go through `Marshal` and are unchanged.

If any of these ran in production against a real store, treat the token as disclosed and
rotate it: `bc.sessions` lists your credentials and `session.revoke` retires one.

## [0.10.2] - 2026-09-30

### Security

- **`WebhookEventHeaders` no longer prints header values when inspected**
  ([#206](https://github.com/basecradle/basecradle-ruby/issues/206)). An inbound
  delivery's headers are the *sender's*, stored verbatim by the platform, so one of them
  may be the sender's own credential — a POST authenticated to an ingest URL carries its
  `Authorization` or `X-Api-Key` right there. `WebhookEventHeaders` is a `Hash`
  descendant and inherited `Hash`'s render, which prints every pair, so
  `logger.debug(event.content.headers)` wrote **another party's secret** into your logs.
  `inspect`, `to_s` and `pp` now render the header names alone, sorted, matching the rule
  every other object in this SDK already followed (`ApiObject#inspect` prints field
  names, never values):

  ```
  #<BaseCradle::WebhookEventHeaders Authorization, Content-Type, X-Api-Key>
  ```

  **Only the human-facing render changed.** Every read is untouched and still wire-exact:
  the case-folded lookup, `fetch`, `each`, `keys`, `to_h`, `to_json`, `==`. If you were
  relying on `inspect` to see values, use `to_h` — which is what it was always for. No
  credential of yours was exposed; the exposure was of whoever sent you the webhook, so
  if you have logged inbound deliveries at debug level, treat those senders' headers as
  disclosed.
- **Two ways a header value still reaches a log, both by design.** `to_json`/`as_json`
  emit the delivery verbatim — that is what a webhook record *is* — so
  `render json: event` and `logger.info(event.to_json)` still write the sender's headers
  in full. And converting away from the type gives up the redaction exactly as it gives up
  the case-folding: `slice`, `except`, `select`, `transform_values` and `to_h` each hand
  back a plain `Hash`, whose `inspect` prints pairs. Only `merge` and `dup` keep the type,
  and so the redaction. Changing what a webhook record *serializes* as is a separate
  decision and is not made here.

## [0.10.1] - 2026-09-30

### Security

- **A `Client` no longer serializes, and never emits its token**
  ([#198](https://github.com/basecradle/basecradle-ruby/issues/198)). A client is a
  connection, not a record, and it defined no `as_json`/`to_json` — so with ActiveSupport
  loaded it fell through to `Object#as_json`, which is `instance_values`, walked
  recursively. Its instance variables include the raw `bc_uat_` token, so
  `render json: { conn: bc }` or `logger.info({ conn: bc }.to_json)` wrote the live
  credential into a response body or a log line, and **a token in a log is a token to
  rotate**. `bc.to_json` now raises `BaseCradle::NotSerializableError`, a
  `BaseCradle::Error`, naming what to serialize instead. Long-standing and latent; no
  token is known to have been emitted.
- **`Client#inspect` and `#to_s` redact the token** — the same exposure through a
  different door. Ruby's default `inspect` dumps every instance variable, so the
  credential printed into every exception message, REPL transcript and `p` call that
  touched a client. Both now read
  `#<BaseCradle::Client base_url="https://basecradle.com" token=[REDACTED]>`, with `to_s`
  the same string because interpolation is the door people reach for without thinking.

### Fixed

- **A collection resource no longer serializes either.** `bc.timelines`, `bc.messages`,
  `timeline.tasks`, any `.filter(...)`, and the `Paginator` behind them are lazy queries,
  not records. ActiveSupport's `Enumerable#as_json` calls `to_a`, so serializing one ran
  a page-by-page GET loop over the whole resource from **inside a view render** and
  emitted every record it fetched. It did *not* reach the token — `Enumerable#as_json`
  shadows the `instance_values` walk above — but a client's instance variables are eight
  collections, so serializing a client fired those loops on its way to the credential.
  All of them now raise the same `NotSerializableError`, before any HTTP, pointing at
  `.to_a` so how much you fetch is a visible act in your own code.
  Without ActiveSupport these calls were useless rather than dangerous
  (`"#<BaseCradle::MessagesResource:0x…>"`, the heap address 0.10.0 removed for models);
  that is closed too.
- **The collection resources' `inspect` is unchanged** and still shows Ruby's default
  ivar dump — which renders the client through the redacting `Client#inspect` above, so
  no token reaches it. Pinned by test so it stays that way.

### Known limitation

The refusals are on the SDK's own objects. An `Enumerator` built from a collection —
`bc.messages.each`, `bc.messages.lazy` — is a plain Ruby object this SDK does not own,
and ActiveSupport gives it an `as_json` that calls `to_a`, so
`render json: { recent: bc.messages.lazy }` still pages the whole resource. No token is
exposed; call `.first(n)` or `.to_a` before handing a query to a renderer.

### Migrating

Nothing to change unless you were serializing a `Client` or a collection, which never
emitted anything useful and, for a client under ActiveSupport, emitted your token. If you
were: serialize the record you meant (`bc.me`, a timeline, a message), or call `.to_a` /
`.first(n)` on a collection first.

## [0.10.0] - 2026-09-30

### Fixed

- **A model serializes as the record it stands for**
  ([#191](https://github.com/basecradle/basecradle-ruby/issues/191)). `ApiObject` defined
  no `to_json`, so serializing *any* model — `bc.me`, a `Timeline`, a `Message`, any
  content object — fell through to Ruby's default and emitted a heap address:
  `"#<BaseCradle::MessageContent:0x000072be94b09…>"`. Silently, with no field names and a
  different value every run. `model.to_json` and `JSON.generate(model)` now emit the
  record, and so does a model nested in an array or a hash. What `to_h` holds is exactly
  what goes out: nothing renamed, nothing dropped, and a field newer than this SDK
  release serialized like any other.
  `WebhookEventHeaders` is unchanged — it subclasses `Hash`, so it already serialized as
  the delivery's headers.
  Long-standing; 0.9.0's typing of `timeline.items` content only widened which read path
  reached it. **0.9.0's Migrating note on `to_json` is superseded by this release.**

### Added

- **`as_json`**, ActiveSupport's serialization hook, returning the same wire `Hash` as
  `to_h`. It is what reaches a model nested inside a structure Rails renders
  (`render json: { user: bc.me }`); a bare `render json: model` calls `to_json` directly
  and never reaches it. Two things to know, neither of which a Rails habit expects:
  - **It returns the same `Hash` as `to_h`, not a copy** — read-only by the same
    convention, where every ActiveSupport `as_json` builds a fresh one. So
    `model.as_json.merge!(extra)` rewrites the model's wire record, and for a wrapped
    child its parent's too. Use `model.to_h.dup` (shallow) if you need to touch it.
  - **Options are accepted and ignored, `only:` and `except:` included** — a model is a
    read of one record, not a presenter. `as_json(except: ["ingest_url"])` returns the
    whole record, silently, and it *disagrees* with `to_json`: with ActiveSupport loaded
    `model.to_json(except: [...])` does redact, because the option reaches `Hash#to_json`.
    Do not route redaction through either — build the subset with
    `model.to_h.except("ingest_url")`.

  `to_json` forwards its argument to `Hash#to_json` rather than swallowing it, so
  `JSON.pretty_generate` pretty-prints; what an unknown option does is the host app's
  `json` version's business (3.x raises, the 2.x older Rubies ship ignores it).

  `to_s` is untouched, so interpolating a model (`"#{model}"`, `puts model`) still shows
  the default object form. `inspect` names the model and its fields; `to_json` / `to_h`
  give the record.

  Minor rather than patch: the `to_json` output is a fix, but `as_json` is new public
  surface and 0.9.0 documented the old behavior as expected — semver takes the higher.

## [0.9.0] - 2026-09-30

### Changed

- **A timeline item's `content` is typed by the item's `type`**
  ([#189](https://github.com/basecradle/basecradle-ruby/issues/189)). `item.content` now
  reads as the same content model the record's own resource returns — `MessageContent`,
  `AssetContent`, `TaskContent` or `WebhookEventContent` — where it was the raw wire
  `Hash`. One record has one shape however you reach it, so everything those models add
  reads down both paths: `timeline.items` gives an `AssetContent` whose `file` is an
  `AssetFile`, and a `webhook_event` row's `content.headers` is the case-folding
  `WebhookEventHeaders` 0.8.0 shipped, so `item.content.headers["X-GitHub-Delivery"]`
  now finds the header it names. The previous release documented that split as a
  boundary; it is now closed, and every future enrichment of a content model arrives on
  both paths at once. The README documents `timeline.items` with a worked example for
  the first time.
- **An item `type` this release does not know keeps reading.** The API is additive-only,
  so an unrecognized `type` is never an error: its content comes back as a plain
  `ApiObject`, and `content["any_field"]` still returns the wire value untouched.
  Upgrading the SDK is what types it. An item carrying *no* `type` is a different thing
  — a malformed response, not a new record kind — and raises `MissingFieldError` the way
  `item.type` itself does, rather than being guessed into the generic case.
- The wire is untouched — `item["content"]`, `ApiObject`'s raw escape hatch, still hands
  back exactly the `Hash` the API sent, and no field is renamed.
  Decided in lockstep with the Python SDK's
  [#210](https://github.com/basecradle/basecradle-python/issues/210); that port is still
  in flight, so the two SDKs reach parity on this when it ships.

### Migrating

`item.content` was a `Hash` and is now an `ApiObject`. Reads of *named* fields get
better — `item.content.body` instead of `item.content["body"]`, and the models' own
enrichments come with them — but three things that worked on a `Hash` no longer do:

- **The `Hash` protocol is gone.** `item.content.fetch("body")`, `.each`, `.keys`,
  `.dig(...)` and `.key?(...)` raise `NoMethodError`. Use the field reader, or
  `item.content.to_h` for the wire `Hash` itself (`item["content"]` gives the same).
- **`to_json` no longer serializes the record.** `item.content.to_json` emits Ruby's
  default `to_s` — `"#<BaseCradle::MessageContent:0x…>"`, an object address with no
  field names — because `ApiObject` defines no `to_json`. That is long-standing for
  every other model in the SDK and now reaches this path too. Serialize
  `item.content.to_h` instead.
  > ⚠️ **Superseded in [0.10.0](#0100---2026-09-30)**, which gives `ApiObject` a
  > `to_json`. `item.content.to_json` emits the record; the `to_h` workaround above is
  > no longer needed. Left as written for the historical record.
- **`inspect` and `==` change, both for the better.** `inspect` names the model and its
  wire fields (`#<BaseCradle::MessageContent body, uuid>`) rather than printing a `Hash`;
  and equality now *holds* between an item's content and the same record fetched
  directly (`timeline.items.first.content == bc.messages.get(uuid).content`), where
  comparing a `Hash` to an `ApiObject` was always false.

## [0.8.0] - 2026-09-30

### Changed

- **`event.content.headers` folds case on lookup**, the way HTTP names headers
  ([#173](https://github.com/basecradle/basecradle-ruby/issues/173)). BaseCradle stores
  header names in canonical Title-Case per segment and does not preserve the sender's
  casing, and the API docs tell consumers to "look them up case-insensitively rather than
  by a vendor's preferred spelling" — but the plain `Hash` the SDK handed back was
  case-sensitive, so a caller who wrote the spelling a vendor publishes (GitHub's
  `X-GitHub-Delivery`) or the lowercase form an HTTP/2 sender emits read a silent `nil`.
  `headers["X-GitHub-Delivery"]`, `headers["X-Github-Delivery"]` and
  `headers["x-github-delivery"]` now all read the header that arrived, and so does every
  other read that takes a header name — `fetch`, `dig`, `values_at`, `fetch_values` and
  `key?` (with `has_key?`, `include?` and `member?`). Only *lookup* folds: the value is
  still a `Hash` of exactly what the wire carried, so `each`, `keys`, `to_h` and `to_json`
  read the platform's own canonical spelling, nothing is renamed, and the methods that
  reshape it (`slice`, `except`, `select`) work on those stored names.
  Matches the Python SDK's
  [#209](https://github.com/basecradle/basecradle-python/pull/209), decided in lockstep.
- **A header that was not delivered is absent, never `nil`** — `headers[name]` and a
  fallback-less `headers.fetch(name)` raise `KeyError` naming the headers that did
  arrive, where before a `nil` could equally have meant "you spelled it wrong".
  `headers.fetch(name, default)` (or a block, which is handed the name as written) and
  `headers.dig(name)` answer for an absent header the way `Hash` does, and a name that is
  not a `String` is not a header name, so it is never matched. A missing *field* is still
  `BaseCradle::MissingFieldError`; a missing *header* is a `KeyError`.
- **Documented the two paths that do not fold**: `event.content["headers"]`, `ApiObject`'s
  raw-wire escape hatch, and a `webhook_event` row of `timeline.items`, whose content is a
  union of four record types (so it is not a `WebhookEventContent`) — both hand back the
  plain wire `Hash`. `bc.webhook_events` and `timeline.webhook_events` give the
  case-folding headers.

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

[0.11.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.11.0
[0.10.4]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.10.4
[0.10.3]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.10.3
[0.10.2]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.10.2
[0.10.1]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.10.1
[0.10.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.10.0
[0.9.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.9.0
[0.8.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.8.0
[0.7.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.7.0
[0.6.1]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.6.1
[0.6.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.6.0
[0.5.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.5.0
[0.4.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.4.0
[0.3.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.3.0
[0.2.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.2.0
[0.1.1]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.1.1
[0.1.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.1.0
