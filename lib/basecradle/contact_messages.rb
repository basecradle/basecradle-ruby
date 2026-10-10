# frozen_string_literal: true

require_relative "api_object"
require_relative "headers"
require_relative "pagination"
require_relative "serialization"
require_relative "user"

module BaseCradle
  # Contact messages and notes are the platform's first **admin-only** surface. Every call
  # in this file answers a non-admin with +NotAnAdminError+ (403, +not_an_admin+) — the
  # SDK sends the request regardless, because the platform, not this library, decides who
  # is an admin. +bc.me.admin+ is present only for an admin, if you want to ask first.

  # --- models ---------------------------------------------------------------------------

  # What a note is about: its subject's record type and uuid. Typed, because a note can be
  # about any kind of record — today it is always a +"contact_message"+.
  class Notable < ApiObject
    attribute :type
    attribute :uuid
  end

  # An admin's dated, signed remark about a record. A note **never changes**: there is no
  # update and no delete, for anyone. One shape everywhere a note appears — fetched alone,
  # listed, or embedded on its subject (+contact_message.notes+).
  class Note < ApiObject
    attribute :uuid
    attribute :body
    attribute :user, wrap: User # the author, nested-actor form
    attribute :notable, wrap: Notable
    attribute :created_at
    attribute :updated_at
  end

  # A contact-page submission's request headers, exactly as the visitor's browser sent
  # them — read through RequestHeaders' rules: case-insensitive lookup, and a render of
  # names and never values, because a visitor's request can carry its own credentials.
  class ContactMessageHeaders < RequestHeaders; end

  # What someone sent through the public contact page, stored with everything the request
  # told the platform and, after the fact, what the risk-assessment vendors said about it.
  # A top-level record, so flat (no +type+ / +content+): +contact_message.uuid+ is its
  # identity, and it embeds its notes in full.
  #
  # Nothing is ever rejected on a score — the record is the data, and an admin decides,
  # with +update_status+ and +add_note+.
  class ContactMessage < ApiObject
    attribute :uuid
    attribute :name
    attribute :email_address
    attribute :body
    # "received" (the default) | "closed" | "spam" — the triage verdict, set with
    # +update_status+. Treat an unrecognized value as forward-compatible, never an error.
    attribute :status
    # The signed-in user who submitted it (nested-actor form), or +nil+ for a visitor
    # without an account.
    attribute :user, wrap: User
    attribute :ip_address
    attribute :user_agent
    attribute :headers, wrap: ContactMessageHeaders
    attribute :honeypot_filled
    attribute :fill_seconds # how long the form took to fill, or nil
    # One self-describing slot per vendor (+vendor+, +api+, +docs+, +fetched_at+,
    # +attempts+, then exactly one of +answer+ / +skipped+ / +error+). A plain Hash, read
    # as the platform sent it — the vendors are the platform's to add and change, so the
    # SDK models none of them. Note the scores do not all run the same way: see
    # https://basecradle.com/docs/api.md#contact-messages.
    attribute :data
    attribute :notes, wrap: Note
    attribute :created_at
    attribute :updated_at

    # Set the triage verdict: +"received"+, +"closed"+ or +"spam"+. It moves in any
    # direction — reopening a closed message is +update_status("received")+.
    #
    # Live object: the API returns the whole contact message, and this object reads it from
    # here on (+status+ and +updated_at+ included), then returns +self+. Raises
    # +ValidationError+ (422) for a status outside the three.
    def update_status(status)
      response = require_client.request("PATCH", "/contact_messages/#{uuid}/status",
                                        json: { "contact_message" => { "status" => status } })
      @data = response.fetch("contact_message")
      self
    end

    # Write a note about this contact message, and return it as a +Note+ (you are its
    # author). Raises +ValidationError+ (422) for a blank body.
    #
    # This object's own +notes+ is not touched: it is the record as fetched, and the API
    # answers with the note alone. Fetch the contact message again
    # (+bc.contact_messages.get(uuid)+) to read it with the new note embedded.
    #
    # Never auto-retried — the notes endpoint takes no +Idempotency-Key+, so a resend after
    # a lost response could write the note twice.
    def add_note(body:)
      response = require_client.request("POST", "/contact_messages/#{uuid}/notes",
                                        json: { "note" => { "body" => body } })
      Note.new(response.fetch("note"), client: @client)
    end
  end

  # --- collections ----------------------------------------------------------------------

  # Every contact message, newest first, auto-paginating — narrow with +.filter(status:)+,
  # or fetch one by uuid. Admin-only.
  #
  #   bc.contact_messages.filter(status: "received").each do |message|
  #     message.update_status("spam") if message.honeypot_filled
  #   end
  class ContactMessagesResource
    include Enumerable
    include NotSerializableCollection

    def initialize(client, filters: {})
      @client = client
      @filters = filters
    end

    def each(&block)
      return enum_for(:each) unless block_given?

      Paginator.new(@client, "/contact_messages", envelope_key: "contact_messages",
                                                  model: ContactMessage, params: @filters).each(&block)
    end

    # A new lazy resource narrowed by status: +"received"+, +"closed"+ or +"spam"+. Any
    # other value is the API's to refuse (+InvalidFilterError+, 400).
    def filter(status: nil)
      filters = @filters.dup
      filters["status"] = status unless status.nil?
      self.class.new(@client, filters: filters)
    end

    # Fetch one contact message by its uuid.
    def get(uuid)
      ContactMessage.new(@client.request("GET", "/contact_messages/#{uuid}").fetch("contact_message"),
                         client: @client)
    end
  end

  # Every note, across every subject, newest first, auto-paginating — or fetch one by uuid.
  # Admin-only. Notes are written from their subject (+contact_message.add_note+), never
  # from here.
  class NotesResource
    include Enumerable
    include NotSerializableCollection

    def initialize(client)
      @client = client
    end

    def each(&block)
      return enum_for(:each) unless block_given?

      Paginator.new(@client, "/notes", envelope_key: "notes", model: Note).each(&block)
    end

    # Fetch one note by its uuid.
    def get(uuid)
      Note.new(@client.request("GET", "/notes/#{uuid}").fetch("note"), client: @client)
    end
  end
end
