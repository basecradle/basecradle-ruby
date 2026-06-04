# frozen_string_literal: true

require "test_helper"

class SessionsTest < Minitest::Test
  include TestSupport

  def setup
    @bc = BaseCradle::Client.new(FAKE_TOKEN)
  end

  def test_lists_sessions_newest_first_with_their_fields
    stub_request(:get, "#{BASE_URL}/users/sessions").to_return(
      status: 200,
      body: { "sessions" => [ session_payload(current: true),
                             session_payload(uuid: WEB_SESSION_UUID, kind: "web", current: false) ],
              "next_cursor" => nil }.to_json
    )

    sessions = @bc.sessions.to_a

    assert_equal 2, sessions.size
    assert(sessions.first.current)
    assert_equal "api", sessions.first.kind
    assert_equal "web", sessions.last.kind
    refute sessions.last.current
  end

  def test_sessions_paginate
    stub_request(:get, "#{BASE_URL}/users/sessions")
      .to_return(status: 200, body: { "sessions" => [ session_payload ], "next_cursor" => "C1" }.to_json)
    stub_request(:get, "#{BASE_URL}/users/sessions").with(query: { "before" => "C1" })
      .to_return(status: 200, body: {
        "sessions" => [ session_payload(uuid: WEB_SESSION_UUID, kind: "web") ], "next_cursor" => nil
      }.to_json)

    assert_equal %w[api web], @bc.sessions.map(&:kind)
  end

  def test_revoke_deletes_that_session
    stub_request(:get, "#{BASE_URL}/users/sessions")
      .to_return(status: 200, body: { "sessions" => [ session_payload ], "next_cursor" => nil }.to_json)
    stub_request(:delete, "#{BASE_URL}/users/sessions/#{API_SESSION_UUID}").to_return(status: 204)

    assert_nil @bc.sessions.first.revoke
    assert_requested(:delete, "#{BASE_URL}/users/sessions/#{API_SESSION_UUID}")
  end

  def test_revoking_the_current_session_is_allowed_not_blocked
    stub_request(:get, "#{BASE_URL}/users/sessions").to_return(
      status: 200, body: { "sessions" => [ session_payload(current: true) ], "next_cursor" => nil }.to_json
    )
    stub_request(:delete, "#{BASE_URL}/users/sessions/#{API_SESSION_UUID}").to_return(status: 204)

    current = @bc.sessions.first
    assert current.current
    current.revoke # the SDK never blocks self-rotation
    assert_requested(:delete, "#{BASE_URL}/users/sessions/#{API_SESSION_UUID}")
  end

  def test_revoke_all_kills_every_session
    stub_request(:delete, "#{BASE_URL}/users/sessions").to_return(status: 204)

    assert_nil @bc.sessions.revoke_all
    assert_requested(:delete, "#{BASE_URL}/users/sessions")
  end
end
