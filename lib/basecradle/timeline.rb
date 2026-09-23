# frozen_string_literal: true

require_relative "api_object"
require_relative "items"
require_relative "user"
require_relative "webhooks"

module BaseCradle
  # One item on a timeline — a message, asset, webhook event, or task. +type+ says which;
  # +content+ is the item itself, wire-exact; +user+ is the author.
  #
  # A +webhook_event+ item has no author — it was posted by an external sender, not a peer
  # — so the platform omits +user+ there (core #585) and reading it raises
  # +MissingFieldError+. Branch on +type+ when you walk a mixed page of items.
  class TimelineItem < ApiObject
    attribute :type
    attribute :created_at
    attribute :user, wrap: User
    attribute :content # shape depends on type — read it wire-exact
  end

  # A timeline: its metadata, owner, participants, lock state — and its verbs.
  #
  # Verbs update this object with exactly what the API confirmed changed (live objects,
  # Rails-style) and return +self+, except +add_participant+ which returns the added user.
  class Timeline < ApiObject
    attribute :uuid
    attribute :name
    attribute :locked
    attribute :created_at
    attribute :updated_at
    attribute :owner, wrap: User
    attribute :participants, wrap: User
    # Present when the timeline is the subject of the response (get / create). List rows
    # don't carry items — fetch the timeline to get them (reading this raises otherwise).
    attribute :items, wrap: TimelineItem

    # The emergency stop: freeze the timeline's content, permanently. Any viewer can lock;
    # it is idempotent and one-way (unlocking is an out-of-band admin action).
    def lock
      response = require_client.request("POST", "/timelines/#{uuid}/lock")
      # The response is moving from a bare {uuid, locked} to the timeline envelope
      # (core #585); read the confirmed state off whichever shape arrived.
      to_h["locked"] = (response["timeline"] || response)["locked"]
      self
    end

    # Permanently delete this timeline and everything on it — messages, assets, tasks,
    # webhook endpoints and their events, participations. Owner-only (an admin may delete
    # any timeline); a mere participant gets NotTimelineOwnerError (a ForbiddenError,
    # code +not_timeline_owner+).
    #
    # A locked timeline is still deletable: locking freezes content, not governance.
    # Returns nil — the timeline is gone, so there is nothing left to return. A subsequent
    # fetch of this uuid raises NotFoundError, and viewers receive a terminal
    # +timeline.deleted+ Event Delivery event whose resource pointer now 404s.
    def delete
      require_client.request("DELETE", "/timelines/#{uuid}")
      nil
    end

    # Add a peer to this timeline (owner or admin only; mutual trust required). Accepts a
    # User or a uuid. Idempotent. Returns the added user (also appended to +participants+).
    def add_participant(user)
      conn = require_client
      response = conn.request(
        "POST", "/timelines/#{uuid}/participations", json: { "user_id" => BaseCradle.uuid_of(user) }
      )
      # The response is moving from a bare nested-actor user to the {"user" => ...}
      # envelope (core #585); take the added user from whichever shape arrived.
      data = response["user"] || response
      added = User.new(data, client: conn)
      roster = (to_h["participants"] ||= [])
      roster << data unless roster.any? { |p| p["uuid"] == added.uuid }
      added
    end

    # Remove a participant from this timeline (owner or admin only). Idempotent.
    def remove_participant(user)
      removed_uuid = BaseCradle.uuid_of(user)
      require_client.request("DELETE", "/timelines/#{uuid}/participations/#{removed_uuid}")
      if to_h.key?("participants")
        to_h["participants"] = to_h["participants"].reject { |p| p["uuid"] == removed_uuid }
      end
      self
    end

    # This timeline's messages: .create(body:) or iterate (newest first).
    def messages
      TimelineMessages.new(require_client, uuid)
    end

    # This timeline's assets: .create(file:, description:) (multipart) or iterate.
    def assets
      TimelineAssets.new(require_client, uuid)
    end

    # This timeline's tasks: .create(instructions:, activate_at:) or iterate.
    def tasks
      TimelineTasks.new(require_client, uuid)
    end

    # This timeline's inbound webhook endpoints: .create(description:) or iterate.
    def webhook_endpoints
      TimelineWebhookEndpoints.new(require_client, uuid)
    end

    # This timeline's webhook events (read-only) — iterate, newest first.
    def webhook_events
      TimelineWebhookEvents.new(require_client, uuid)
    end
  end
end
