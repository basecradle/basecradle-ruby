# frozen_string_literal: true

require_relative "errors"

module BaseCradle
  # The uuid for a value that may be a model object or a uuid string. A model's identity
  # is its top-level +uuid+ (timelines, users) or, failing that, its +content.uuid+
  # (items, webhook endpoints) — mirroring how the API addresses them.
  def self.uuid_of(value)
    return value unless value.is_a?(ApiObject)

    data = value.to_h
    data["uuid"] || data.fetch("content")["uuid"]
  end

  # The per-request headers carrying an optional idempotency key — +nil+ when no key was
  # given (so a create without a key sends no +Idempotency-Key+ header, and is never
  # auto-retried). Shared by the four content-create methods.
  def self.idempotency_headers(key)
    key.nil? ? nil : { "Idempotency-Key" => key }
  end

  # A read-only, wire-exact view of one API JSON object.
  #
  # Subclasses declare their wire fields with the +attribute+ macro; readers return the
  # wire value untouched (names mirror the API's JSON exactly). Two deliberate behaviors:
  #
  # - A field the API added after this SDK release is still readable via +[]+ (the API is
  #   additive-only — the SDK never hides what the platform says).
  # - A declared field the API did *not* return raises +MissingFieldError+ (with an
  #   explanation) rather than returning +nil+ — a silent nil could mean "hidden from you"
  #   or "actually null", and the SDK never guesses which.
  #
  # Objects built by a client carry a reference to it, so resource verbs added in later
  # releases (e.g. +timeline.lock+) can act on the platform.
  class ApiObject
    def initialize(data, client: nil)
      @data = data
      @client = client
    end

    # Declare a wire field. +wrap:+ names a model class to wrap the value in (a Hash
    # becomes that model; an Array of Hashes becomes an Array of that model).
    def self.attribute(name, wrap: nil)
      key = name.to_s
      define_method(name) do
        raise_missing(key) unless @data.key?(key)
        value = @data[key]
        wrap ? wrap_value(value, wrap) : value
      end
    end

    # Raw wire access — returns whatever the API sent for +key+ (or +nil+ if absent),
    # without wrapping. The escape hatch for fields newer than this SDK release.
    def [](key)
      @data[key.to_s]
    end

    # The underlying wire data (a Hash). Read-only by convention.
    def to_h
      @data
    end

    def ==(other)
      other.instance_of?(self.class) && other.to_h == @data
    end
    alias eql? ==

    def hash
      [ self.class, @data ].hash
    end

    def inspect
      "#<#{self.class} #{@data.keys.sort.join(', ')}>"
    end

    private

    # The client this object came from — required by verbs that call the API (later releases).
    def require_client
      return @client if @client

      raise Error, "This #{self.class} is not attached to a BaseCradle client, so it cannot " \
                   "call the API. Objects obtained from a client (bc.me, ...) are attached " \
                   "automatically."
    end

    def wrap_value(value, klass)
      case value
      when Hash
        klass.new(value, client: @client)
      when Array
        value.map { |item| item.is_a?(Hash) ? klass.new(item, client: @client) : item }
      else
        value
      end
    end

    def raise_missing(key)
      raise MissingFieldError,
            "The API did not return #{key.inspect} for this #{self.class}. It may be " \
            "access-gated (see the API docs on access tiers) or not part of this response " \
            "form. Fields present: #{@data.keys.sort.inspect}"
    end
  end

  # A record in reference form — just a uuid to dereference (e.g. an item's +timeline+,
  # or a webhook event's +webhook_endpoint+). Fetch the full record when you need it.
  class Reference < ApiObject
    attribute :uuid
  end
end
