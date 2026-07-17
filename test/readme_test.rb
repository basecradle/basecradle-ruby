# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

# The doc-truth test: every Ruby example in the README runs, verbatim, against a mocked
# API. Truth in Documentation (the constitution): docs that lie are worse than none. If
# the README drifts from the SDK, CI fails here.
class ReadmeTest < Minitest::Test
  include TestSupport

  README = File.expand_path("../README.md", __dir__)

  def ruby_blocks
    File.read(README).scan(/```ruby\n(.*?)```/m).map(&:first)
  end

  def setup
    ENV["BASECRADLE_TOKEN"] = FAKE_TOKEN
    # Examples that reference ./report.pdf run in a temp dir where that file exists.
    @workdir = Dir.mktmpdir
    File.write(File.join(@workdir, "report.pdf"), "%PDF-1.7 fabricated example bytes")
    @original_dir = Dir.pwd
    Dir.chdir(@workdir)

    stub_request(:post, "#{BASE_URL}/session")
      .to_return(status: 201,
                 body: { "token" => FAKE_TOKEN, "start_here" => "#{BASE_URL}/docs/api.md" }.to_json)
    stub_request(:get, "#{BASE_URL}/users/dashboard")
      .to_return(status: 200, body: DASHBOARD_RESPONSE.to_json)
    stub_request(:get, "#{BASE_URL}/timelines")
      .to_return(status: 200, body: { "timelines" => [ timeline_payload ], "next_cursor" => nil }.to_json)
    stub_request(:post, "#{BASE_URL}/timelines")
      .to_return(status: 201, body: { "timeline" => timeline_payload(participants: []), "items" => [] }.to_json)
    stub_request(:post, %r{#{BASE_URL}/timelines/.+/participations})
      .to_return(status: 201, body: NOVA.to_json)
    stub_request(:post, %r{#{BASE_URL}/timelines/.+/lock})
      .to_return(status: 200, body: { "uuid" => TIMELINE_UUID, "locked" => true }.to_json)
    stub_request(:delete, %r{#{BASE_URL}/timelines/[^/]+\z}).to_return(status: 204)
    stub_request(:post, %r{#{BASE_URL}/timelines/.+/messages})
      .to_return(status: 201, body: { "message" => message_payload }.to_json)
    stub_request(:post, %r{#{BASE_URL}/timelines/.+/assets})
      .to_return(status: 201, body: { "asset" => asset_payload }.to_json)
    stub_request(:post, %r{#{BASE_URL}/timelines/.+/tasks})
      .to_return(status: 201, body: { "task" => task_payload }.to_json)
    stub_request(:post, %r{#{BASE_URL}/tasks/.+/cancellation})
      .to_return(status: 200, body: { "task" => task_payload(status: "cancelled") }.to_json)
    stub_request(:get, %r{#{BASE_URL}/messages})
      .to_return(status: 200, body: { "messages" => [ message_payload ], "next_cursor" => nil }.to_json)
    stub_request(:get, %r{#{BASE_URL}/tasks})
      .to_return(status: 200, body: { "tasks" => [ task_payload ], "next_cursor" => nil }.to_json)
    stub_request(:post, %r{#{BASE_URL}/timelines/.+/webhook_endpoints})
      .to_return(status: 201, body: { "webhook_endpoint" => webhook_endpoint_payload }.to_json)
    stub_request(:post, %r{#{BASE_URL}/webhook_endpoints/.+/enablement})
      .to_return(status: 200, body: { "webhook_endpoint" => webhook_endpoint_payload }.to_json)
    stub_request(:delete, %r{#{BASE_URL}/webhook_endpoints/.+/enablement})
      .to_return(status: 200, body: { "webhook_endpoint" => webhook_endpoint_payload }.to_json)
    stub_request(:post, %r{#{BASE_URL}/webhook_endpoints/.+/rotation})
      .to_return(status: 200, body: { "webhook_endpoint" => webhook_endpoint_payload }.to_json)
    stub_request(:get, %r{#{BASE_URL}/webhook_events})
      .to_return(status: 200, body: { "webhook_events" => [ webhook_event_payload ], "next_cursor" => nil }.to_json)
    stub_request(:get, "#{BASE_URL}/users/sessions").to_return(
      status: 200,
      body: { "sessions" => [ session_payload(current: true),
                              session_payload(uuid: WEB_SESSION_UUID, name: "stale ci runner",
                                              current: false) ],
              "next_cursor" => nil }.to_json
    )
    stub_request(:delete, %r{#{BASE_URL}/users/sessions/.+}).to_return(status: 204)
    stub_request(:delete, "#{BASE_URL}/session").to_return(status: 204)
    stub_request(:get, "#{BASE_URL}/users")
      .to_return(status: 200, body: { "users" => [ directory_user_payload(trusts_you: true) ] }.to_json)
    stub_request(:get, "#{BASE_URL}/users/#{NOVA['uuid']}")
      .to_return(status: 200, body: { "user" => directory_user_payload(trusts_you: true) }.to_json)
    stub_request(:post, %r{#{BASE_URL}/users/.+/trust})
      .to_return(status: 201,
                 body: { "user" => trusted_peer_user_payload(you_trust: true, trusts_you: true) }.to_json)
  end

  def teardown
    ENV.delete("BASECRADLE_TOKEN")
    Dir.chdir(@original_dir)
    FileUtils.remove_entry(@workdir)
    super
  end

  def test_readme_has_ruby_examples
    refute_empty ruby_blocks, "README.md has no ```ruby code blocks"
  end

  def test_every_ruby_block_runs_verbatim
    printed = +""
    ruby_blocks.each_with_index do |code, index|
      out, = capture_io { run_block(code) }
      printed << out
    rescue StandardError, ScriptError => e
      flunk "README ruby block ##{index} raised #{e.class}: #{e.message}\n\n#{code}"
    end

    # The hero example prints the peer's identity and the machine contract URL.
    assert_includes printed, "nova"
    assert_includes printed, "https://basecradle.com/docs/api.yaml"
  end

  private

  # Run a block with its local variables isolated (so blocks don't leak into each other),
  # at the top level so `require`/`puts` behave as a reader's script would.
  def run_block(code)
    eval("lambda do\n#{code}\nend", TOPLEVEL_BINDING, README).call # rubocop:disable Security/Eval
  end
end
