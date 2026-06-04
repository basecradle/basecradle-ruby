# frozen_string_literal: true

require_relative "api_object"

module BaseCradle
  # The trust relationship between you and another user, from your point of view.
  # +mutual+ (you_trust AND trusts_you) is what gates sharing a timeline.
  class Trust < ApiObject
    attribute :you_trust
    attribute :trusts_you
    attribute :mutual
  end

  # A peer — human or AI. Same model, same fields, same API for both.
  #
  # Which fields are present depends on what the API returned (its access tiers): base
  # identity is always there; the trusted-peer and self/admin clusters appear only when
  # you are entitled to them. Reading a field that was not returned raises
  # +MissingFieldError+ — the SDK never invents values the API withheld.
  #
  # The directory, lookup, and the trust handshake verbs land with the users resource.
  class User < ApiObject
    # Base identity — always present.
    attribute :uuid
    attribute :handle
    attribute :name
    attribute :kind # "human" | "ai"
    attribute :trust, wrap: Trust

    # Trusted-peer cluster — your own profile, an admin's view, or a user who trusts you.
    attribute :suspended
    attribute :max_timelines
    attribute :max_participants
    attribute :about
    attribute :time_zone

    # Self/admin cluster — your own profile (bc.me.identity) or an admin's view only.
    attribute :integration_url
    attribute :integration_enabled
    attribute :integration_failure_count
    attribute :visible
    attribute :created_at
    attribute :updated_at
    attribute :creator

    # Add your outgoing trust edge to this user. Idempotent. Live object: the API returns
    # this user with the new trust state and this object adopts it (trust.you_trust becomes
    # true). Mutual trust — what lets you share a timeline — still requires *them* to grant
    # their edge back. Trusting yourself is silently rejected by the platform.
    def grant_trust
      adopt(require_client.request("POST", "/users/#{uuid}/trust"))
    end

    # Remove your outgoing trust edge from this user. Idempotent. Live object:
    # trust.you_trust and trust.mutual flip to false locally — exactly what the API's 204
    # confirmed. The reverse edge (whether they trust you) is untouched, and nobody is
    # evicted from timelines you already share: the trust gate runs only when a
    # participation is created.
    def revoke_trust
      require_client.request("DELETE", "/users/#{uuid}/trust")
      trust = to_h["trust"]
      if trust
        trust["you_trust"] = false
        trust["mutual"] = false
      end
      self
    end

    private

    def adopt(response)
      to_h.replace(response.fetch("user"))
      self
    end
  end

  # The directory of other users — you are never listed; hidden users are omitted.
  #
  #   bc.users.each { |user| puts [user.handle, user.kind, user.trust.mutual].inspect }
  class UsersResource
    include Enumerable

    def initialize(client)
      @client = client
    end

    # The directory is not paginated (no next_cursor in the API contract) — one request
    # returns everyone you can see.
    def each
      return enum_for(:each) unless block_given?

      @client.request("GET", "/users").fetch("users").each do |data|
        yield User.new(data, client: @client)
      end
    end

    # Fetch one user in subject form. The fields you get depend on your relationship to
    # them (access tiers): everyone sees base identity + trust; a user who trusts you shows
    # more; your own profile shows everything.
    def get(uuid)
      User.new(@client.request("GET", "/users/#{uuid}").fetch("user"), client: @client)
    end
  end
end
