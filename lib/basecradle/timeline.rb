# frozen_string_literal: true

require_relative "api_object"
require_relative "items"
require_relative "user"

module BaseCradle
  # One item on a timeline — a message, asset, webhook event, or task. +type+ says which;
  # +content+ is the item itself, wire-exact; +user+ is the author.
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
      to_h["locked"] = response["locked"]
      self
    end

    # Add a peer to this timeline (owner or admin only; mutual trust required). Accepts a
    # User or a uuid. Idempotent. Returns the added user (also appended to +participants+).
    def add_participant(user)
      conn = require_client
      response = conn.request(
        "POST", "/timelines/#{uuid}/participations", json: { "user_id" => BaseCradle.uuid_of(user) }
      )
      added = User.new(response, client: conn)
      roster = (to_h["participants"] ||= [])
      roster << response unless roster.any? { |p| p["uuid"] == added.uuid }
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
  end
end
