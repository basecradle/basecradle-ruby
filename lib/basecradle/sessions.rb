# frozen_string_literal: true

require_relative "api_object"
require_relative "pagination"

module BaseCradle
  # One credential you hold — a web sign-in or a bc_uat_ API token.
  #
  # +current+ is true on exactly one session: the one making this request. Check it
  # before revoking, so you don't kill your own credential by accident — unless that is
  # exactly what you mean to do (legitimate self-rotation; see +revoke+).
  class Session < ApiObject
    attribute :uuid
    attribute :name # the label given at mint time ("ci runner", "production agent", ...)
    attribute :ip_address
    attribute :user_agent
    attribute :created_at
    attribute :last_used_at # nil if never used; tracked at up to an hour of granularity
    attribute :kind         # "api" (Bearer token) | "web" (browser cookie session)
    attribute :current      # true on exactly one row: the session making this request

    # Revoke this credential. It stops working **instantly** — its next request is a 401.
    #
    # WARNING: revoking your own *current* session is allowed (legitimate self-rotation),
    # and it kills the very token this client is using — after it, this client's next call
    # raises AuthenticationError. If you need continuity, mint a replacement with
    # BaseCradle::Client.login(...) *before* revoking this one. A lost token cannot be
    # recovered, only revoked and re-minted.
    def revoke
      require_client.request("DELETE", "/users/sessions/#{uuid}")
      nil
    end
  end

  # Every credential you hold — iterable, newest first, auto-paginating.
  #
  #   bc.sessions.each do |session|
  #     session.revoke if session.kind == "api" && !session.current
  #   end
  class SessionsResource
    include Enumerable

    def initialize(client)
      @client = client
    end

    def each(&block)
      return enum_for(:each) unless block_given?

      Paginator.new(@client, "/users/sessions", envelope_key: "sessions", model: Session).each(&block)
    end

    # Destroy **every** session you hold — web sign-ins and API tokens alike.
    #
    # WARNING: this is the "I leaked something, kill everything" lever, and it includes
    # **the token this client is using**. After it returns, this client is dead: its next
    # call raises AuthenticationError. Mint a fresh token with
    # BaseCradle::Client.login(email_address:, password:) to continue.
    def revoke_all
      @client.request("DELETE", "/users/sessions")
      nil
    end
  end
end
