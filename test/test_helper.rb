# frozen_string_literal: true

require "minitest/autorun"
require "webmock/minitest"

# Tests never hit the network. The one exception — the live spec drift-guard — opts
# back in explicitly and lives under test/live/ (run via `rake test:live`).
WebMock.disable_net_connect!

require "basecradle"
