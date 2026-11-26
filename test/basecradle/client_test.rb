# frozen_string_literal: true

require "test_helper"

class ClientTest < Minitest::Test
  include TestSupport

  def setup
    # The token-resolution tests set and clear BASECRADLE_TOKEN. Remember whatever the
    # developer had exported so the suite restores it rather than deleting a variable it
    # never created (assigning nil unsets). Captured first: teardown runs even when the
    # rest of setup raises.
    @original_token = ENV["BASECRADLE_TOKEN"]
    @bc = BaseCradle::Client.new(FAKE_TOKEN)
  end

  def teardown
    ENV["BASECRADLE_TOKEN"] = @original_token
    super
  end

  # --- construction & token resolution ---------------------------------------------------

  def test_uses_an_explicit_token
    assert_equal FAKE_TOKEN, @bc.token
  end

  def test_falls_back_to_the_environment_variable
    ENV["BASECRADLE_TOKEN"] = FAKE_TOKEN
    assert_equal FAKE_TOKEN, BaseCradle::Client.new.token
  end

  def test_raises_when_no_token_is_available
    ENV.delete("BASECRADLE_TOKEN")
    error = assert_raises(BaseCradle::MissingTokenError) { BaseCradle::Client.new }
    assert_match(/BASECRADLE_TOKEN/, error.message)
  end

  # --- a token HTTP cannot carry is refused when the client is built (#301) -----------------
  #
  # The idempotency key's rule (BaseCradle.header_value_defect), applied to the token:
  # printable ASCII, with spaces or tabs only between characters. Anything else raises
  # ArgumentError from Client.new, never stripped or repaired, and no rendering of the error
  # shows any part of the token, not even the character at fault. Nothing is stubbed for
  # these, and none can send: the client is never built.

  # Asserts the refusal, its "where", and that no rendering of it carries the token: no
  # slice of it, and not the character at fault (+fault+), raw or inspected.
  def assert_token_refused(token, where, fault: nil)
    error = assert_raises(ArgumentError, token.inspect) { BaseCradle::Client.new(token) }
    assert_match(/\AThe token cannot be sent in an HTTP header: /, error.message)
    assert_includes error.message, where, token.inspect
    assert_includes error.message, "It is not shown here, as it is a credential."
    assert_nil error.cause
    [ error.message, error.inspect, error.full_message, error.detailed_message ].each do |rendered|
      refute_includes rendered, FAKE_TOKEN[0, 12], token.inspect
      refute_includes rendered, FAKE_TOKEN[12, 15], token.inspect
      refute_includes rendered, FAKE_TOKEN[-12..], token.inspect
      next unless fault

      refute_includes rendered.b, fault.b, token.inspect
      refute_includes rendered, fault.inspect, token.inspect
    end
    error
  end

  # The usual case: a token read from a file or an env file, newline kept (Unix, Windows,
  # old Mac). Net::HTTP refused CR and LF, but only when the first request was built.
  def test_a_token_with_a_trailing_newline_is_refused_and_says_so
    [ "\n", "\r\n", "\r" ].each do |ending|
      error = assert_token_refused(FAKE_TOKEN + ending, "the character at index 39 is a control character")
      assert_includes error.message, "A token read from a file or an env file often keeps its trailing newline."
    end
  end

  def test_a_token_from_the_environment_with_its_newline_is_refused
    ENV["BASECRADLE_TOKEN"] = "#{FAKE_TOKEN}\n"
    error = assert_raises(ArgumentError) { BaseCradle::Client.new }
    assert_includes error.message, "the character at index 39 is a control character"
    refute_includes error.full_message, FAKE_TOKEN[0, 12]
  end

  # Whitespace at either end: Net::HTTP sent it, and a hop strips it.
  def test_a_token_with_whitespace_at_either_end_is_refused
    [ " #{FAKE_TOKEN}", "#{FAKE_TOKEN} ", "\t#{FAKE_TOKEN}", "#{FAKE_TOKEN}\t", " " ].each do |token|
      error = assert_token_refused(token, "it begins or ends with whitespace, which a header value cannot")
      refute_includes error.message, "trailing newline"
      assert_includes error.message, "Check where the token was read from."
    end
  end

  # Every other control character: Net::HTTP sent each one as given.
  def test_a_token_with_another_control_character_is_refused
    [ "\0", "\x01", "\v", "\f", "\x1f", "\x7f" ].each do |char|
      token = FAKE_TOKEN[0, 20] + char + FAKE_TOKEN[20..]
      error = assert_token_refused(token, "the character at index 20 is a control character", fault: char)
      refute_includes error.message, "trailing newline"
    end
    assert_token_refused("\0", "the character at index 0 is a control character", fault: "\0")
  end

  # Non-ASCII: Net::HTTP sent the raw bytes. An invalid byte is not ASCII either, and a
  # string whose encoding is not ASCII-compatible is refused as a whole.
  def test_a_token_with_a_non_ascii_character_is_refused
    assert_token_refused("#{FAKE_TOKEN[0..-2]}é", "the character at index 38 is not ASCII", fault: "é")
    assert_token_refused("#{FAKE_TOKEN[0..-2]}\xff".dup.force_encoding("UTF-8"), "the character at index 38 is not ASCII",
                         fault: "\xff".dup.force_encoding("UTF-8"))
    assert_token_refused("#{FAKE_TOKEN[0..-2]}\xff".b, "the character at index 38 is not ASCII", fault: "\xff".b)
    assert_token_refused(FAKE_TOKEN.encode("UTF-16LE"), "its encoding, UTF-16LE, is not ASCII-compatible")
  end

  # Never stripped: a token HTTP can carry is kept exactly as given. Spaces or tabs between
  # characters are the key's rule too (the Python SDK reads it the same way).
  def test_a_token_http_can_carry_is_accepted_as_given
    [ FAKE_TOKEN, FAKE_TOKEN.b, "#{FAKE_TOKEN[0, 20]} #{FAKE_TOKEN[20..]}", "a\tb" ].each do |token|
      assert_equal token, BaseCradle::Client.new(token).token
    end
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

  # A 2xx body that is not JSON is loud, never a silent nil: +request+ speaks JSON (as the
  # Python SDK's does), and the one text endpoint has its own reader (bc.dashboard_md). Only
  # an *error* body that fails to parse becomes nil — the typed error still comes from the
  # status. Decided on #249.
  def test_request_raises_rather_than_returning_nil_for_a_non_json_success_body
    stub_request(:get, "#{BASE_URL}/users/dashboard.md").to_return(status: 200, body: "# Dashboard")

    assert_raises(JSON::ParserError) { @bc.request("GET", "/users/dashboard.md") }
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
    error = assert_raises(ArgumentError) { BaseCradle::Client.new(FAKE_TOKEN, max_retries: -1) }
    assert_equal "max_retries must be >= 0", error.message
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

  # A whitespace-only key is no key — the platform cannot dedupe on it — so the POST it
  # rides is as unsafe to resend as an unkeyed one (#288).
  def test_never_retries_a_post_whose_key_is_only_whitespace
    bc = BaseCradle::Client.new(FAKE_TOKEN, max_retries: 3)
    stub_request(:post, "#{BASE_URL}/x").to_timeout

    stub_method(bc, :backoff, nil) do
      assert_raises(BaseCradle::APIConnectionError) do
        bc.request("POST", "/x", json: { "a" => 1 }, headers: { "Idempotency-Key" => " \t " })
      end
    end
    assert_requested(:post, "#{BASE_URL}/x", times: 1)
  end

  def test_backoff_doubles_from_the_base_and_caps_at_the_max
    bc = BaseCradle::Client.new(FAKE_TOKEN)
    slept = []
    bc.define_singleton_method(:sleep) { |seconds| slept << seconds }

    (1..10).each { |attempt| bc.send(:backoff, attempt) }

    assert_equal [ 0.5, 1.0, 2.0, 4.0, 8.0, 8.0, 8.0, 8.0, 8.0, 8.0 ], slept # the tenth sleeps 8, not 256
  end

  # --- login -----------------------------------------------------------------------------

  def test_login_mints_a_token_and_returns_an_authenticated_client
    stub_login

    client = BaseCradle::Client.login(email_address: "nova@example.com", password: "s3cret")

    assert_equal FAKE_TOKEN, client.token
    assert_equal "#{BASE_URL}/docs/api.md", client.start_here
    assert_requested(:post, "#{BASE_URL}/session") do |req|
      body = JSON.parse(req.body)
      body["email_address"] == "nova@example.com" && body["password"] == "s3cret"
    end
  end

  # The mint response carries the credential it just issued, in the same shape
  # bc.sessions lists — so the caller can find and revoke what it minted.
  def test_login_exposes_the_minted_session
    stub_login

    session = BaseCradle::Client.login(email_address: "nova@example.com", password: "s3cret").session

    assert_instance_of BaseCradle::Session, session
    assert_equal API_SESSION_UUID, session.uuid
    assert_equal "api", session.kind
    assert(session.current)
  end

  # It is the client's own token, so revoking it is self-rotation — the sharp edge the
  # SDK allows by design. The session is attached to the client that minted it.
  def test_the_minted_session_can_revoke_itself
    stub_login
    stub_request(:delete, "#{BASE_URL}/users/sessions/#{API_SESSION_UUID}").to_return(status: 204)

    client = BaseCradle::Client.login(email_address: "nova@example.com", password: "s3cret")

    assert_nil client.session.revoke
    assert_requested(:delete, "#{BASE_URL}/users/sessions/#{API_SESSION_UUID}")
  end

  # A client built from a saved token never saw a mint response, so it has no session to
  # report — and the SDK reports nothing rather than inventing one.
  def test_a_client_built_from_a_token_has_no_minted_session
    assert_nil BaseCradle::Client.new(FAKE_TOKEN).session
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

  # Refused before POST /session, so a bad count never mints a credential the caller would
  # never receive. Nothing is stubbed: a mint that went out would fail here.
  def test_login_refuses_a_negative_max_retries_before_minting
    error = assert_raises(ArgumentError) do
      BaseCradle::Client.login(email_address: "nova@example.com", password: "secret", max_retries: -1)
    end
    assert_equal "max_retries must be >= 0", error.message
    assert_not_requested :post, "#{BASE_URL}/session"
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

  # The documented POST /session response: the token, the minted session, start_here.
  def stub_login
    stub_request(:post, "#{BASE_URL}/session").to_return(
      status: 201,
      body: { "token" => FAKE_TOKEN, "session" => session_payload,
              "start_here" => "#{BASE_URL}/docs/api.md" }.to_json
    )
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

  # --- change password -------------------------------------------------------------------

  # Fabricated passwords, from the docs' own worked example.
  OLD_PASSWORD = "correct-horse-battery-staple"
  NEW_PASSWORD = "Tr0ub4dor&3-new"

  # The happy-path call, so each test below names only what it varies.
  def change_password(new_password: NEW_PASSWORD)
    @bc.change_password(current_password: OLD_PASSWORD, password: new_password,
                        password_confirmation: new_password)
  end

  def test_change_password_sends_the_three_fields_and_returns_nil
    stub_request(:patch, "#{BASE_URL}/users/password").to_return(status: 204)

    assert_nil change_password

    assert_requested(:patch, "#{BASE_URL}/users/password") do |req|
      req.headers["Authorization"] == "Bearer #{FAKE_TOKEN}" &&
        req.headers["Content-Type"] == "application/json" &&
        JSON.parse(req.body) == { "current_password" => OLD_PASSWORD,
                                  "password" => NEW_PASSWORD,
                                  "password_confirmation" => NEW_PASSWORD }
    end
  end

  def test_change_password_raises_when_the_current_password_is_wrong
    stub_request(:patch, "#{BASE_URL}/users/password")
      .to_return(status: 422, body: problem("current_password_incorrect", 422).to_json)

    assert_raises(BaseCradle::CurrentPasswordIncorrectError) { change_password }
  end

  def test_change_password_raises_when_the_confirmation_differs
    stub_request(:patch, "#{BASE_URL}/users/password")
      .to_return(status: 422, body: problem("password_confirmation_mismatch", 422).to_json)

    assert_raises(BaseCradle::PasswordConfirmationMismatchError) do
      @bc.change_password(current_password: OLD_PASSWORD, password: NEW_PASSWORD,
                          password_confirmation: "Tr0ub4dor&3-typo")
    end
  end

  def test_change_password_surfaces_the_models_errors_when_the_new_password_is_too_weak
    weak = problem("validation_failed", 422,
                   errors: { "password" => [ "is too short (minimum is 10 characters)" ] })
    stub_request(:patch, "#{BASE_URL}/users/password").to_return(status: 422, body: weak.to_json)

    error = assert_raises(BaseCradle::ValidationError) { change_password(new_password: "short") }

    assert_equal [ "is too short (minimum is 10 characters)" ], error.errors["password"]
  end

  def test_change_password_keeps_the_calling_clients_token
    # Documented: a change signs out every *other* session, but the token that made the
    # call keeps working, so this client goes on as before.
    stub_request(:patch, "#{BASE_URL}/users/password").to_return(status: 204)
    # Matched on the token, so a change_password that quietly invalidated it (the way
    # sign_out does) would leave this request unstubbed rather than passing.
    stub_request(:get, "#{BASE_URL}/users/dashboard")
      .with(headers: { "Authorization" => "Bearer #{FAKE_TOKEN}" })
      .to_return(status: 200, body: DASHBOARD_RESPONSE.to_json)

    change_password

    assert_equal "nova", @bc.me.identity.handle
  end

  def test_change_password_is_never_auto_retried
    # An unkeyed write: even with retries on, a lost connection raises rather than
    # re-sending a password change whose first attempt may have landed.
    bc = BaseCradle::Client.new(FAKE_TOKEN, max_retries: 3)
    stub_request(:patch, "#{BASE_URL}/users/password").to_timeout

    stub_method(bc, :backoff, nil) do
      assert_raises(BaseCradle::APIConnectionError) do
        bc.change_password(current_password: OLD_PASSWORD, password: NEW_PASSWORD,
                           password_confirmation: NEW_PASSWORD)
      end
    end
    assert_requested(:patch, "#{BASE_URL}/users/password", times: 1)
  end
end
