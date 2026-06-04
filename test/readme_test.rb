# frozen_string_literal: true

require "test_helper"

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
    stub_request(:get, "#{BASE_URL}/users/dashboard")
      .to_return(status: 200, body: DASHBOARD_RESPONSE.to_json)
  end

  def teardown
    ENV.delete("BASECRADLE_TOKEN")
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
