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
end
