# frozen_string_literal: true

require "test_helper"

class ClientTest < Minitest::Test
  include TestSupport

  def setup
    @bc = BaseCradle::Client.new(FAKE_TOKEN)
  end

  # --- construction & token resolution ---------------------------------------------------

  def test_uses_an_explicit_token
    assert_equal FAKE_TOKEN, @bc.token
  end

  def test_falls_back_to_the_environment_variable
    ENV["BASECRADLE_TOKEN"] = FAKE_TOKEN
    assert_equal FAKE_TOKEN, BaseCradle::Client.new.token
  ensure
    ENV.delete("BASECRADLE_TOKEN")
  end

  def test_raises_when_no_token_is_available
    ENV.delete("BASECRADLE_TOKEN")
    error = assert_raises(BaseCradle::MissingTokenError) { BaseCradle::Client.new }
    assert_match(/BASECRADLE_TOKEN/, error.message)
  end

  def test_inspect_does_not_leak_the_token
    refute_includes @bc.inspect, FAKE_TOKEN
  end

  # --- request: success paths ------------------------------------------------------------

  def test_request_returns_parsed_json
    stub_request(:get, "#{BASE_URL}/timelines")
      .to_return(status: 200, body: { "timelines" => [], "next_cursor" => nil }.to_json)

    assert_equal({ "timelines" => [], "next_cursor" => nil }, @bc.request("GET", "/timelines"))
  end

  def test_request_returns_nil_on_204
    stub_request(:delete, "#{BASE_URL}/users/sessions").to_return(status: 204)

    assert_nil @bc.request("DELETE", "/users/sessions")
  end

  def test_request_returns_nil_on_empty_body
    stub_request(:get, "#{BASE_URL}/empty").to_return(status: 200, body: "")

    assert_nil @bc.request("GET", "/empty")
  end

  def test_request_sends_auth_and_identifying_headers
    stub_request(:get, "#{BASE_URL}/timelines").to_return(status: 200, body: "{}")

    @bc.request("GET", "/timelines")

    assert_requested(:get, "#{BASE_URL}/timelines") do |req|
      req.headers["Authorization"] == "Bearer #{FAKE_TOKEN}" &&
        req.headers["Accept"] == "application/json" &&
        req.headers["User-Agent"] == "basecradle-ruby/#{BaseCradle::VERSION}"
    end
  end

  def test_request_serializes_a_json_body
    stub_request(:post, "#{BASE_URL}/timelines").to_return(status: 201, body: "{}")

    @bc.request("POST", "/timelines", json: { "timeline" => { "name" => "Incident response" } })

    assert_requested(:post, "#{BASE_URL}/timelines") do |req|
      req.headers["Content-Type"] == "application/json" &&
        JSON.parse(req.body) == { "timeline" => { "name" => "Incident response" } }
    end
  end

  def test_request_encodes_query_params
    stub_request(:get, "#{BASE_URL}/tasks").with(query: { "status" => "pending" })
      .to_return(status: 200, body: "{}")

    @bc.request("GET", "/tasks", params: { "status" => "pending" })

    assert_requested(:get, "#{BASE_URL}/tasks", query: { "status" => "pending" })
  end

  # --- request: error paths --------------------------------------------------------------

  def test_request_raises_typed_error_for_problem_json
    stub_request(:get, "#{BASE_URL}/timelines/x")
      .to_return(status: 404, body: problem("not_found", 404).to_json,
                 headers: { "Content-Type" => "application/problem+json" })

    error = assert_raises(BaseCradle::NotFoundError) { @bc.request("GET", "/timelines/x") }
    assert_equal "not_found", error.code
    assert_equal 404, error.status
  end

  def test_request_raises_rate_limited_with_retry_after
    stub_request(:get, "#{BASE_URL}/timelines")
      .to_return(status: 429, body: problem("rate_limited", 429).to_json,
                 headers: { "Retry-After" => "42" })

    error = assert_raises(BaseCradle::RateLimitedError) { @bc.request("GET", "/timelines") }
    assert_equal 42, error.retry_after
  end

  def test_request_raises_base_error_for_non_problem_body
    stub_request(:get, "#{BASE_URL}/timelines")
      .to_return(status: 502, body: "<html>Bad Gateway</html>")

    error = assert_raises(BaseCradle::Error) { @bc.request("GET", "/timelines") }
    assert_equal 502, error.status
    assert_nil error.code
  end

  def test_request_wraps_connection_failures
    stub_request(:get, "#{BASE_URL}/timelines").to_timeout

    assert_raises(BaseCradle::APIConnectionError) { @bc.request("GET", "/timelines") }
  end

  def test_request_merges_per_call_headers
    stub_request(:get, "#{BASE_URL}/x").to_return(status: 200, body: "{}")

    @bc.request("GET", "/x", headers: { "Idempotency-Key" => "k1" })

    assert_requested(:get, "#{BASE_URL}/x") { |req| req.headers["Idempotency-Key"] == "k1" }
  end

  # --- retries ---------------------------------------------------------------------------

  def test_does_not_retry_by_default
    stub_request(:get, "#{BASE_URL}/timelines").to_timeout

    assert_raises(BaseCradle::APIConnectionError) { @bc.request("GET", "/timelines") }
    assert_requested(:get, "#{BASE_URL}/timelines", times: 1)
  end

  def test_rejects_a_negative_max_retries
    assert_raises(ArgumentError) { BaseCradle::Client.new(FAKE_TOKEN, max_retries: -1) }
  end

  def test_retries_a_get_on_a_lost_connection_then_succeeds
    bc = BaseCradle::Client.new(FAKE_TOKEN, max_retries: 2)
    stub_request(:get, "#{BASE_URL}/timelines").to_timeout.then
                                               .to_return(status: 200, body: "{}")

    stub_method(bc, :backoff, nil) { assert_equal({}, bc.request("GET", "/timelines")) }
    assert_requested(:get, "#{BASE_URL}/timelines", times: 2)
  end

  def test_gives_up_after_max_retries_are_exhausted
    bc = BaseCradle::Client.new(FAKE_TOKEN, max_retries: 2)
    stub_request(:get, "#{BASE_URL}/timelines").to_timeout

    stub_method(bc, :backoff, nil) do
      assert_raises(BaseCradle::APIConnectionError) { bc.request("GET", "/timelines") }
    end
    assert_requested(:get, "#{BASE_URL}/timelines", times: 3) # the call + 2 retries
  end

  def test_retries_a_keyed_post
    bc = BaseCradle::Client.new(FAKE_TOKEN, max_retries: 1)
    stub_request(:post, "#{BASE_URL}/x").to_timeout.then.to_return(status: 201, body: "{}")

    stub_method(bc, :backoff, nil) do
      bc.request("POST", "/x", json: { "a" => 1 }, headers: { "Idempotency-Key" => "k1" })
    end
    assert_requested(:post, "#{BASE_URL}/x", times: 2)
  end

  def test_never_retries_an_unkeyed_post
    bc = BaseCradle::Client.new(FAKE_TOKEN, max_retries: 3)
    stub_request(:post, "#{BASE_URL}/x").to_timeout

    stub_method(bc, :backoff, nil) do
      assert_raises(BaseCradle::APIConnectionError) { bc.request("POST", "/x", json: { "a" => 1 }) }
    end
    assert_requested(:post, "#{BASE_URL}/x", times: 1)
  end

  # --- login -----------------------------------------------------------------------------

  def test_login_mints_a_token_and_returns_an_authenticated_client
    stub_request(:post, "#{BASE_URL}/session")
      .to_return(status: 201,
                 body: { "token" => FAKE_TOKEN, "start_here" => "#{BASE_URL}/docs/api.md" }.to_json)

    client = BaseCradle::Client.login(email_address: "nova@example.com", password: "s3cret")

    assert_equal FAKE_TOKEN, client.token
    assert_equal "#{BASE_URL}/docs/api.md", client.start_here
    assert_requested(:post, "#{BASE_URL}/session") do |req|
      body = JSON.parse(req.body)
      body["email_address"] == "nova@example.com" && body["password"] == "s3cret"
    end
  end

  def test_login_sends_optional_name
    stub_request(:post, "#{BASE_URL}/session")
      .to_return(status: 201, body: { "token" => FAKE_TOKEN }.to_json)

    BaseCradle::Client.login(email_address: "nova@example.com", password: "s3cret",
                             name: "ci runner")

    assert_requested(:post, "#{BASE_URL}/session") do |req|
      JSON.parse(req.body)["name"] == "ci runner"
    end
  end

  def test_login_forwards_max_retries_to_the_client
    stub_request(:post, "#{BASE_URL}/session")
      .to_return(status: 201, body: { "token" => FAKE_TOKEN }.to_json)

    client = BaseCradle::Client.login(email_address: "nova@example.com", password: "s3cret",
                                      max_retries: 3)

    assert_equal 3, client.max_retries
  end

  def test_login_raises_typed_error_on_bad_credentials
    stub_request(:post, "#{BASE_URL}/session")
      .to_return(status: 401, body: problem("invalid_credentials", 401).to_json)

    assert_raises(BaseCradle::InvalidCredentialsError) do
      BaseCradle::Client.login(email_address: "nova@example.com", password: "wrong")
    end
  end

  # --- sign out --------------------------------------------------------------------------

  def test_sign_out_deletes_the_current_session_and_returns_nil
    stub_request(:delete, "#{BASE_URL}/session").to_return(status: 204)

    assert_nil @bc.sign_out
    assert_requested(:delete, "#{BASE_URL}/session") do |req|
      req.headers["Authorization"] == "Bearer #{FAKE_TOKEN}"
    end
  end

  def test_sign_out_revokes_the_calling_clients_own_token_by_design
    # Sharp by design: after sign_out the token is dead, so the client's next call 401s.
    stub_request(:delete, "#{BASE_URL}/session").to_return(status: 204)
    stub_request(:get, "#{BASE_URL}/users/dashboard")
      .to_return(status: 401, body: problem("unauthorized", 401).to_json)

    @bc.sign_out # never blocked — a peer manages its own keys

    assert_raises(BaseCradle::AuthenticationError) { @bc.me }
  end
end
