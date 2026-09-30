# frozen_string_literal: true

require_relative "api_object"
require_relative "items"
require_relative "user"
require_relative "webhooks"

module BaseCradle
  # One item on a timeline — a message, asset, webhook event, or task. +type+ says which;
  # +content+ is the item itself, typed by that +type+; +user+ is the author.
  #
  # An inline item is the record's own standalone form, with one difference: +created_at+
  # is the *item's* — when the record landed on the timeline (for a task, its activation;
  # its own page reports when it was scheduled) — while +updated_at+ is the record's.
  #
  # Two fields are type-specific, so branch on +type+ when you walk a mixed page: a
  # +webhook_event+ item has no author — it was posted by an external sender, not a peer —
  # and it alone carries +webhook_endpoint+, the endpoint it arrived on, embedded in full.
  # Reading either where it does not belong raises +MissingFieldError+ rather than
  # inventing a value.
  class TimelineItem < ApiObject
    # The content model each item +type+ reads as — the very class that +type+'s own
    # resource returns, so one record has one shape however you reach it. A +type+ this
    # release does not know is not in here on purpose; see +content+. Internal: the
    # dispatch table is not API surface, so re-keying it is never a breaking change.
    CONTENT_MODELS = {
      "message" => MessageContent,
      "asset" => AssetContent,
      "task" => TaskContent,
      "webhook_event" => WebhookEventContent
    }.freeze
    private_constant :CONTENT_MODELS

    attribute :type
    attribute :created_at
    attribute :updated_at
    attribute :user, wrap: User
    attribute :timeline, wrap: Reference
    attribute :webhook_endpoint, wrap: WebhookEndpoint # webhook_event items only

    # The item itself, as the content model its +type+ names: a MessageContent,
    # AssetContent, TaskContent or WebhookEventContent — the same object the record's own
    # page hands back. So a record reads identically down either path, enrichments
    # included (+item.content.headers+ folds case exactly as
    # +bc.webhook_events.get(uuid).content.headers+ does), and an item's content +==+ the
    # same record fetched directly.
    #
    # The API is additive-only, so an item +type+ newer than this SDK release must keep
    # reading rather than raise: its content comes back as a plain ApiObject, whose +[]+
    # still returns every wire field untouched. Upgrading the SDK is what types it.
    def content
      raise_missing("content") unless to_h.key?("content")
      # The two ways a +type+ can be unusable are different answers, not one. A type the
      # API sent that this release has no model for is the forward-compatible case and
      # falls back below; an item carrying no +type+ at all is a malformed response (the
      # spec marks it required), and the SDK raises rather than guessing which — the same
      # promise ApiObject makes for every other withheld field.
      raise_untypable unless to_h.key?("type")

      wrap_value(to_h["content"], CONTENT_MODELS.fetch(type, ApiObject))
    end

    private

    # Reading +type+ here would raise about a field the caller never asked for, on an
    # object whose "fields present" list includes the +content+ they did ask for. Name
    # the dependency between the two instead, and the escape hatch that still works.
    def raise_untypable
      raise MissingFieldError,
            "This #{self.class}'s content cannot be typed: the API did not return " \
            "\"type\" for it, and an item's content model is chosen by its type. The " \
            "wire content is still readable with item[\"content\"]. " \
            "Fields present: #{to_h.keys.sort.inspect}"
    end
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
    #
    # Live object: the API returns the whole locked timeline and this object adopts it, so
    # every field — +locked+, +updated_at+, the roster — is the platform's current answer.
    def lock
      adopt(require_client.request("POST", "/timelines/#{uuid}/lock"))
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
      data = response.fetch("user")
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

    private

    # Live-object update: the API returned the complete timeline, so this object points at
    # it from here on. Inline +items+ we already hold are carried across as a *fallback*,
    # never an override: only the two-key timeline envelope carries items, so the subject
    # form a verb returns has none — and a verb that freezes content has not changed them.
    def adopt(response)
      updated = response.fetch("timeline")
      updated = { "items" => to_h["items"] }.merge(updated) if to_h.key?("items")
      @data = updated
      self
    end
  end
end
