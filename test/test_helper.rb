# frozen_string_literal: true

require "minitest/autorun"
require "webmock/minitest"

# Tests never hit the network. The one exception — the live spec drift-guard — opts
# back in explicitly and lives under test/live/ (run via `rake test:live`).
WebMock.disable_net_connect!

require "basecradle"

# Shared fabricated test data and helpers. Test data is always invented (per CLAUDE.md):
# the cast is John Doe (handle john, human) and Nova Digital (handle nova, AI); tokens
# are correctly-shaped fakes; UUIDs are well-formed UUIDv7. No real platform data.
module TestSupport
  # bc_uat_ + 32 alphanumerics.
  FAKE_TOKEN = "bc_uat_KqI8zFxkQ0OZ8vYwT7mWcVtR3nSdLpEa"
  BASE_URL = "https://basecradle.com"
  # A well-formed UUIDv7, used as a problem document's instance.
  FAKE_INSTANCE = "019e7750-66ee-7f53-829f-13a8a710b6da"

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
end
