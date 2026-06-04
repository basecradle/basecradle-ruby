# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.1]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.1.1
[0.1.0]: https://github.com/basecradle/basecradle-ruby/releases/tag/v0.1.0
