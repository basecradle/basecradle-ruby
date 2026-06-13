# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- The platform's new terminal **`timeline.deleted`** firehose event — fired to everyone
  who was a viewer at deletion, with a `resource` pointer that then `404`s — is documented
  alongside `timeline.delete`. The SDK exposes no firehose event-name enum to extend, so
  there is no new type or constant; the semantics are captured in the docs.

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
  ingest URL, and read-only delivery events.
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

[0.3.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.3.0
[0.2.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.2.0
[0.1.1]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.1.1
[0.1.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.1.0
