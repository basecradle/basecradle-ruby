# frozen_string_literal: true

require "test_helper"

class UsersTest < Minitest::Test
  include TestSupport

  def setup
    @bc = BaseCradle::Client.new(FAKE_TOKEN)
  end

  def test_directory_iterates_in_one_unpaginated_request
    stub_request(:get, "#{BASE_URL}/users").to_return(
      status: 200,
      body: { "users" => [ directory_user_payload(user: JOHN), directory_user_payload(user: NOVA) ] }.to_json
    )

    handles = @bc.users.map(&:handle)

    assert_equal %w[john nova], handles
    assert_requested(:get, "#{BASE_URL}/users", times: 1)
    assert_not_requested(:get, "#{BASE_URL}/users", query: hash_including("before"))
  end

  def test_get_returns_a_user_with_trust
    stub_request(:get, "#{BASE_URL}/users/#{NOVA['uuid']}")
      .to_return(status: 200, body: { "user" => directory_user_payload(trusts_you: true) }.to_json)

    nova = @bc.users.get(NOVA["uuid"])

    assert_equal "nova", nova.handle
    assert_instance_of BaseCradle::Trust, nova.trust
    assert nova.trust.trusts_you
    refute nova.trust.mutual
  end

  def test_a_directory_row_withholds_the_trusted_peer_cluster
    stub_request(:get, "#{BASE_URL}/users")
      .to_return(status: 200, body: { "users" => [ directory_user_payload ] }.to_json)

    # Base identity + trust are present; the trusted-peer cluster is not → raises.
    user = @bc.users.first
    assert_equal "nova", user.handle
    assert_raises(BaseCradle::MissingFieldError) { user.about }
  end

  def test_trusted_view_exposes_roles_and_admin_predicate
    stub_request(:get, "#{BASE_URL}/users/#{NOVA['uuid']}").to_return(
      status: 200,
      body: { "user" => trusted_peer_user_payload(roles: %w[admin], trusts_you: true) }.to_json
    )

    nova = @bc.users.get(NOVA["uuid"])

    assert_equal %w[admin], nova.roles
    assert nova.admin?
  end

  def test_a_peer_without_the_admin_role_is_not_admin
    stub_request(:get, "#{BASE_URL}/users/#{NOVA['uuid']}").to_return(
      status: 200, body: { "user" => trusted_peer_user_payload(roles: [], trusts_you: true) }.to_json
    )

    nova = @bc.users.get(NOVA["uuid"])

    assert_empty nova.roles
    refute nova.admin?
  end

  def test_an_untrusted_view_withholds_roles_so_admin_cannot_guess
    stub_request(:get, "#{BASE_URL}/users")
      .to_return(status: 200, body: { "users" => [ directory_user_payload ] }.to_json)

    # The directory withholds the trusted-peer cluster, roles included — so neither roles nor
    # the admin? it derives may invent a value; both raise rather than guess "no roles".
    user = @bc.users.first
    assert_raises(BaseCradle::MissingFieldError) { user.roles }
    assert_raises(BaseCradle::MissingFieldError) { user.admin? }
  end

  def test_grant_trust_adopts_the_returned_state
    stub_request(:get, "#{BASE_URL}/users/#{NOVA['uuid']}")
      .to_return(status: 200, body: { "user" => directory_user_payload }.to_json)
    nova = @bc.users.get(NOVA["uuid"])
    stub_request(:post, "#{BASE_URL}/users/#{NOVA['uuid']}/trust").to_return(
      status: 201,
      body: { "user" => trusted_peer_user_payload(you_trust: true, trusts_you: true) }.to_json
    )

    refute nova.trust.you_trust
    nova.grant_trust

    assert nova.trust.you_trust
    assert nova.trust.mutual
    assert_equal "UTC", nova.time_zone # the adopted payload carries the trusted-peer cluster
  end

  def test_revoke_trust_flips_local_state_without_touching_the_reverse_edge
    stub_request(:get, "#{BASE_URL}/users/#{NOVA['uuid']}").to_return(
      status: 200,
      body: { "user" => directory_user_payload(you_trust: true, trusts_you: true) }.to_json
    )
    nova = @bc.users.get(NOVA["uuid"])
    stub_request(:delete, "#{BASE_URL}/users/#{NOVA['uuid']}/trust").to_return(status: 204)

    assert nova.trust.mutual
    assert_same nova, nova.revoke_trust

    refute nova.trust.you_trust
    refute nova.trust.mutual
    assert nova.trust.trusts_you # the reverse edge is untouched
  end
end
