# frozen_string_literal: true

require "test_helper"

class DashboardTest < Minitest::Test
  include TestSupport

  def setup
    @bc = BaseCradle::Client.new(FAKE_TOKEN)
    stub_request(:get, "#{BASE_URL}/users/dashboard")
      .to_return(status: 200, body: DASHBOARD_RESPONSE.to_json)
  end

  def test_me_returns_a_dashboard
    assert_instance_of BaseCradle::Dashboard, @bc.me
  end

  def test_identity_is_a_user_mirroring_the_wire
    identity = @bc.me.identity

    assert_instance_of BaseCradle::User, identity
    assert_equal "nova", identity.handle
    assert_equal "ai", identity.kind
    assert_instance_of BaseCradle::Trust, identity.trust
    assert identity.trust.mutual
  end

  def test_nested_sections_read_through
    me = @bc.me

    assert_equal "BaseCradle", me.environment.name
    assert_instance_of BaseCradle::DashboardTimelines, me.interaction.timelines
    assert_equal 3, me.interaction.timelines.count
    assert_equal "https://basecradle.com/docs/api.yaml", me.documentation.openapi
    assert_equal "https://rubygems.org/gems/basecradle", me.documentation.sdks.ruby.package
  end

  def test_identity_carries_roles_on_the_self_view
    identity = @bc.me.identity

    assert_equal [], identity.roles # your own subject always carries the trusted-peer cluster
    refute identity.admin?
  end

  # The sixth section rides the Dashboard only for an admin — its presence is the answer.
  def test_an_admin_sees_the_admin_section
    admin = DASHBOARD_RESPONSE.merge(
      "admin" => { "contact_messages_url" => "https://basecradle.com/contact_messages.json",
                   "notes_url" => "https://basecradle.com/notes.json",
                   "guide_url" => "https://basecradle.com/docs/api.md#contact-messages" }
    )
    stub_request(:get, "#{BASE_URL}/users/dashboard").to_return(status: 200, body: admin.to_json)

    section = @bc.me.admin

    assert_instance_of BaseCradle::DashboardAdmin, section
    assert_equal "https://basecradle.com/contact_messages.json", section.contact_messages_url
    assert_equal "https://basecradle.com/notes.json", section.notes_url
    assert_equal "https://basecradle.com/docs/api.md#contact-messages", section.guide_url
  end

  def test_everyone_else_has_no_admin_section_and_reading_it_raises
    assert_raises(BaseCradle::MissingFieldError) { @bc.me.admin }
  end

  def test_me_is_fetched_fresh_on_every_access
    @bc.me
    @bc.me

    assert_requested(:get, "#{BASE_URL}/users/dashboard", times: 2)
  end

  def test_a_withheld_field_raises_rather_than_returning_nil
    # A lean directory-style identity (base fields only) — the self/admin cluster is absent.
    lean = DASHBOARD_RESPONSE.merge(
      "identity" => { "uuid" => "u", "handle" => "john", "name" => "John Doe", "kind" => "human",
                      "trust" => { "you_trust" => false, "trusts_you" => false, "mutual" => false } }
    )
    stub_request(:get, "#{BASE_URL}/users/dashboard").to_return(status: 200, body: lean.to_json)

    assert_raises(BaseCradle::MissingFieldError) { @bc.me.identity.integration_url }
  end

  # --- dashboard_md: the same page as Markdown --------------------------------------------

  PRIMER = "# Your Dashboard\n\nYou are **Nova Digital** (`@nova`) — an AI peer.\n\n" \
           "{\"not\": \"json, and not parsed\"}\n\n"

  def stub_primer(**response)
    stub_request(:get, "#{BASE_URL}/users/dashboard.md")
      .to_return({ status: 200, headers: { "Content-Type" => "text/markdown; charset=utf-8" } }
                 .merge(response))
  end

  def test_dashboard_md_returns_the_body_verbatim_as_a_utf8_string
    stub_primer(body: PRIMER.b) # the wire hands back bytes; the SDK labels them UTF-8

    primer = @bc.dashboard_md

    assert_equal PRIMER, primer # trailing whitespace and a JSON-looking line survive
    assert_equal Encoding::UTF_8, primer.encoding
    assert primer.valid_encoding?
  end

  def test_dashboard_md_rides_the_clients_authenticated_connection
    stub_primer(body: PRIMER)

    @bc.dashboard_md

    # The .md path picks the representation; a strict Accept would invite a 406.
    assert_requested(:get, "#{BASE_URL}/users/dashboard.md") do |req|
      req.headers["Authorization"] == "Bearer #{FAKE_TOKEN}" &&
        req.headers["Accept"] == "*/*" &&
        req.headers["User-Agent"] == "basecradle-ruby/#{BaseCradle::VERSION}"
    end
  end

  def test_dashboard_md_returns_an_empty_string_never_nil
    stub_primer(body: "")

    assert_equal "", @bc.dashboard_md
  end

  def test_dashboard_md_raises_the_typed_error_for_problem_json
    stub_primer(status: 401, body: problem("unauthorized", 401).to_json,
                headers: { "Content-Type" => "application/problem+json" })

    error = assert_raises(BaseCradle::AuthenticationError) { @bc.dashboard_md }
    assert_equal "unauthorized", error.code
  end

  def test_dashboard_md_raises_the_base_error_for_a_non_problem_failure
    stub_primer(status: 406, body: "<html>Not Acceptable</html>",
                headers: { "Content-Type" => "text/html" })

    error = assert_raises(BaseCradle::Error) { @bc.dashboard_md }
    assert_equal 406, error.status
  end

  def test_dashboard_md_retries_a_lost_connection_when_retries_are_on
    bc = BaseCradle::Client.new(FAKE_TOKEN, max_retries: 1)
    stub_request(:get, "#{BASE_URL}/users/dashboard.md").to_timeout.then
                                                       .to_return(status: 200, body: PRIMER)

    stub_method(bc, :backoff, nil) { assert_equal PRIMER, bc.dashboard_md }
    assert_requested(:get, "#{BASE_URL}/users/dashboard.md", times: 2)
  end

  def test_dashboard_md_is_fetched_fresh_on_every_call
    stub_primer(body: PRIMER)

    @bc.dashboard_md
    @bc.dashboard_md

    assert_requested(:get, "#{BASE_URL}/users/dashboard.md", times: 2)
  end
end
