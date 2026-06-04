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
  end
end
