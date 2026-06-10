# frozen_string_literal: true

require "minitest/autorun"
require "webmock/minitest"

# Tests never hit the network. The one exception — the live spec drift-guard — opts
# back in explicitly and lives under test/live/ (run via `rake test:live`).
WebMock.disable_net_connect!

require "basecradle"

# Guarantee WebMock's stubs and request history are cleared after every test, so no
# test can see another's requests (assert_requested counts the full history). Runs even
# if a test defines its own teardown without calling super.
module ResetWebMockAfterEach
  def after_teardown
    super
    WebMock.reset!
  end
end
Minitest::Test.prepend(ResetWebMockAfterEach)

# Shared fabricated test data and helpers. Test data is always invented (per CLAUDE.md):
# the cast is John Doe (handle john, human) and Nova Digital (handle nova, AI); tokens
# are correctly-shaped fakes; UUIDs are well-formed UUIDv7. No real platform data.
module TestSupport
  # bc_uat_ + 32 alphanumerics.
  FAKE_TOKEN = "bc_uat_KqI8zFxkQ0OZ8vYwT7mWcVtR3nSdLpEa"
  BASE_URL = "https://basecradle.com"
  # A well-formed UUIDv7, used as a problem document's instance.
  FAKE_INSTANCE = "019e7750-66ee-7f53-829f-13a8a710b6da"

  # The fictional cast, in nested-actor form (uuid, handle, name, kind).
  JOHN = { "uuid" => "019e7750-66ee-7e50-9e54-3bf8c3d6a8f1", "handle" => "john",
           "name" => "John Doe", "kind" => "human" }.freeze
  NOVA = { "uuid" => "019e7750-66ee-79c8-ad8a-bbb6ea7c2bcc", "handle" => "nova",
           "name" => "Nova Digital", "kind" => "ai" }.freeze

  TIMELINE_UUID = "019e7750-66ee-7f53-829f-13a8a710b6da"

  # The documented Dashboard example (GET /users/dashboard), spec-complete: Nova Digital,
  # an AI peer viewing their own profile (so every access tier is present).
  DASHBOARD_RESPONSE = {
    "identity" => {
      "uuid" => "019e4b4c-3f21-7a90-b5e2-6c1f0a7d3e88",
      "handle" => "nova",
      "name" => "Nova Digital",
      "kind" => "ai",
      "trust" => { "you_trust" => true, "trusts_you" => true, "mutual" => true },
      "suspended" => false,
      "max_timelines" => 15,
      "max_participants" => 1,
      "about" => nil,
      "time_zone" => "UTC",
      "integration_url" => nil,
      "integration_enabled" => false,
      "integration_failure_count" => 0,
      "visible" => true,
      "created_at" => "2026-01-01T00:00:00.000Z",
      "updated_at" => "2026-01-01T00:00:00.000Z",
      "creator" => nil,
      "roles" => []
    },
    "environment" => {
      "name" => "BaseCradle",
      "summary" => "A communication platform and research lab where humans and AI are equal peers.",
      "you_are" => "a first-class peer here, not a tool."
    },
    "interaction" => {
      "timelines" => { "url" => "https://basecradle.com/timelines.json", "count" => 3 },
      "assets_url" => "https://basecradle.com/assets.json",
      "messages_url" => "https://basecradle.com/messages.json",
      "tasks_url" => "https://basecradle.com/tasks.json",
      "webhook_endpoints_url" => "https://basecradle.com/webhook_endpoints.json",
      "webhook_events_url" => "https://basecradle.com/webhook_events.json"
    },
    "account" => {
      "profile_url" => "https://basecradle.com/users/019e4b4c-3f21-7a90-b5e2-6c1f0a7d3e88.json",
      "sessions_url" => "https://basecradle.com/users/sessions.json",
      "change_password_url" => "https://basecradle.com/users/password/edit"
    },
    "documentation" => {
      "user_guide" => "https://basecradle.com/docs/user_guide.md",
      "api" => "https://basecradle.com/docs/api.md",
      "changelog" => "https://basecradle.com/docs/changelog.md",
      "openapi" => "https://basecradle.com/docs/api.yaml",
      "reference" => "https://basecradle.com/docs/api/reference",
      "sdks" => {
        "python" => {
          "repository" => "https://github.com/basecradle/basecradle-python",
          "package" => "https://pypi.org/project/basecradle/"
        },
        "ruby" => {
          "repository" => "https://github.com/basecradle/basecradle-ruby",
          "package" => "https://rubygems.org/gems/basecradle"
        }
      }
    }
  }.freeze

  module_function

  # Build a problem+json document the way the API does.
  def problem(code, status, detail: nil, title: nil, **extra)
    {
      "type" => "https://basecradle.com/docs/api#error-#{code}",
      "title" => title || code.split("_").map(&:capitalize).join(" "),
      "status" => status,
      "code" => code,
      "detail" => detail || "Fabricated detail for #{code}.",
      "instance" => FAKE_INSTANCE
    }.merge(extra.transform_keys(&:to_s))
  end

  # A timeline in subject form (the docs' documented example), without items.
  def timeline_payload(uuid: TIMELINE_UUID, name: "Incident response", locked: false, **overrides)
    {
      "uuid" => uuid,
      "name" => name,
      "locked" => locked,
      "created_at" => "2026-01-01T00:00:00.000Z",
      "updated_at" => "2026-01-02T00:00:00.000Z",
      "owner" => JOHN,
      "participants" => [ NOVA ]
    }.merge(overrides.transform_keys(&:to_s))
  end

  # One item's shared envelope (type, created_at, user, timeline-reference, content).
  def item_payload(type, content, user: JOHN, timeline_uuid: TIMELINE_UUID)
    {
      "type" => type,
      "created_at" => "2026-01-02T00:00:00.000Z",
      "user" => user,
      "timeline" => { "uuid" => timeline_uuid },
      "content" => content
    }
  end

  def message_payload(uuid: "019e7750-66ee-7c4f-bcdc-7c5d2eddc662", body: "Hello from a peer.", **kw)
    item_payload("message", { "uuid" => uuid, "body" => body }, **kw)
  end

  def asset_payload(uuid: "019e7750-66ee-7327-bc25-f4e64b0b3a02", description: "Quarterly report", **kw)
    file = {
      "filename" => "report.pdf", "byte_size" => 184_320, "content_type" => "application/pdf",
      "checksum" => "Yp9p9C8m6Xv2qS1nKQ0r3w==",
      "url" => "https://basecradle.com/rails/active_storage/blobs/redirect/abc123/report.pdf"
    }
    item_payload("asset", { "uuid" => uuid, "description" => description, "file" => file }, **kw)
  end

  def task_payload(uuid: "019e7750-66ee-7f8e-a8c5-2c2cf95e2c0b", instructions: "Review the report.",
                   activate_at: "2026-07-01T15:00:00.000Z", status: "pending", **kw)
    item_payload("task", { "uuid" => uuid, "instructions" => instructions,
                           "activate_at" => activate_at, "status" => status }, **kw)
  end

  WEBHOOK_ENDPOINT_UUID = "019e7750-66ee-79fc-a07f-0301cf1ace97"
  INGEST_URL = "https://basecradle.com/webhooks/019e7750-66ee-705a-803c-b25c5ee9b1f3"

  # A webhook endpoint in subject form. No user block (it belongs to the timeline).
  def webhook_endpoint_payload(uuid: WEBHOOK_ENDPOINT_UUID, description: "CI notifications",
                               enabled: true, ingest_url: INGEST_URL, timeline_uuid: TIMELINE_UUID)
    {
      "type" => "webhook_endpoint",
      "created_at" => "2026-01-02T00:00:00.000Z",
      "timeline" => { "uuid" => timeline_uuid },
      "content" => {
        "uuid" => uuid, "description" => description, "enabled" => enabled,
        "ingest_url" => ingest_url,
        "verification" => { "enabled" => false, "signature_header" => "X-Signature",
                            "verifier" => "hmac_sha256_hex" }
      }
    }
  end

  # A lean directory row: base identity + trust only (the docs' documented example).
  def directory_user_payload(user: NOVA, you_trust: false, trusts_you: false)
    user.merge(
      "trust" => { "you_trust" => you_trust, "trusts_you" => trusts_you,
                   "mutual" => you_trust && trusts_you }
    )
  end

  # The middle access tier: a user who trusts you (adds the trusted-peer cluster, +roles+
  # included). +roles+ defaults to none, the realistic case for a non-operator peer.
  def trusted_peer_user_payload(user: NOVA, roles: [], **trust)
    directory_user_payload(user: user, **trust).merge(
      "suspended" => false, "max_timelines" => 15, "max_participants" => 1,
      "about" => "Building things at BaseCradle.", "time_zone" => "UTC", "roles" => roles
    )
  end

  API_SESSION_UUID = "019e84e4-9c0d-76a1-be70-0296c897b10b"
  WEB_SESSION_UUID = "019e84e4-9c0d-7170-abf1-69869d3ca827"

  # A session row (the docs' documented example).
  def session_payload(uuid: API_SESSION_UUID, name: "production agent", kind: "api", current: true,
                      last_used_at: "2026-01-02T12:00:00.000Z")
    {
      "uuid" => uuid,
      "name" => name,
      "ip_address" => kind == "api" ? "203.0.113.10" : "198.51.100.7",
      "user_agent" => kind == "api" ? "basecradle-ruby/0.0.1" : "Mozilla/5.0 (Macintosh)",
      "created_at" => "2026-01-02T00:00:00.000Z",
      "last_used_at" => last_used_at,
      "kind" => kind,
      "current" => current
    }
  end

  # A webhook event in subject form. No user block.
  def webhook_event_payload(uuid: "019e7750-66ee-7ab2-b3a1-e1b87de9d3b6",
                            endpoint_uuid: WEBHOOK_ENDPOINT_UUID, timeline_uuid: TIMELINE_UUID,
                            payload: '{"status":"ok"}')
    {
      "type" => "webhook_event",
      "created_at" => "2026-01-02T00:00:00.000Z",
      "timeline" => { "uuid" => timeline_uuid },
      "webhook_endpoint" => { "uuid" => endpoint_uuid },
      "content" => {
        "uuid" => uuid, "content_type" => "application/json",
        "headers" => { "HTTP_X_EXAMPLE_EVENT" => "ping" }, "payload" => payload,
        "ingest_token_at_receipt" => "019e7750-66ee-705a-803c-b25c5ee9b1f3"
      }
    }
  end
end
