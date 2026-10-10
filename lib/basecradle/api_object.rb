# frozen_string_literal: true

require "json"

require_relative "errors"
require_relative "rendering"

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
    # A record renders as its field names — never its values, which are whatever the API
    # sent (a webhook endpoint's ingest_url among them).
    include RendersNamesOnly

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

    # The wire record, for a serializer — ActiveSupport's hook, and what reaches a model
    # nested inside a structure Rails renders (<tt>render json: { user: bc.me }</tt>).
    # A bare <tt>render json: model</tt> calls +to_json+ instead and never comes here.
    #
    # Returns +to_h+: the wire keys, nothing renamed, nothing dropped, and a field newer
    # than this release carried like any other. (It is the record *as this object holds
    # it* — for a Timeline fetched whole, that is the API's two-key envelope merged into
    # one object, so it carries +items+ alongside the timeline's own fields.)
    #
    # Two traps, because neither is what a Rails habit expects:
    #
    # - **It is the same Hash +to_h+ returns, not a copy** — read-only by the same
    #   convention, where every ActiveSupport +as_json+ builds a fresh one. So
    #   <tt>model.as_json.merge!(extra)</tt> rewrites the model's wire record, and for a
    #   wrapped child its parent's too (a child wraps the parent's own nested Hash).
    #   +to_h.dup+ if you need to touch it; note that is shallow.
    # - **Options are accepted and ignored, +only:+ and +except:+ included** — a model is
    #   a read of one record, not a presenter. +as_json(except: ["ingest_url"])+ returns
    #   the whole record, *silently*. Worse, it disagrees with +to_json+: with
    #   ActiveSupport loaded <tt>model.to_json(except: [...])</tt> *does* redact, because
    #   the option reaches +Hash#to_json+. Do not rely on either — build the subset
    #   yourself with <tt>model.to_h.except("ingest_url")</tt>.
    def as_json(*)
      to_h
    end

    # The wire record as JSON. Without this a model fell through to Ruby's default and
    # emitted a heap address — silently, with no field names and a different value every
    # run. +JSON.generate+ and +Array#to_json+ / +Hash#to_json+ call this, so a model
    # nested in either serializes correctly too.
    #
    # The argument is forwarded to +Hash#to_json+ rather than swallowed, so
    # +JSON.pretty_generate+ pretty-prints — and what an unknown option does is the host
    # app's json version's business, not this SDK's: json 3.x raises on an unknown
    # keyword, the json 2.x that older Rubies ship ignores it, and ActiveSupport acts on
    # +only:+ / +except:+. See +as_json+ above: do not route redaction through either.
    def to_json(*args)
      to_h.to_json(*args)
    end

    def ==(other)
      other.instance_of?(self.class) && other.to_h == @data
    end
    alias eql? ==

    def hash
      [ self.class, @data ].hash
    end

    private

    # The record's wire field names, sorted — never their values. A record holds whatever
    # the API sent, which for a webhook endpoint includes its ingest_url.
    #
    # Sorted by their string form, not by `sort`: a record can be rebuilt from a cached
    # hash (the README says so), and a caller whose cache layer symbolized some keys hands
    # us mixed types, which `sort` refuses with `comparison of Symbol with String failed`.
    # That used to raise from `inspect` alone and now would raise from interpolation and
    # `pp` too — a render that blows up a log line is worse than the disorder it avoids.
    # RequestHeaders#render_body (formerly WebhookEventHeaders') has always done this, for
    # the same reason.
    #
    # nil, not "", for a record with no fields: the module renders nil as the bare class,
    # and `"#<BaseCradle::Message >"` with its dangling space was never intended output.
    def render_body
      return nil if @data.empty?

      @data.keys.sort_by(&:to_s).join(", ")
    end

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

  # A record in reference form — just a uuid to dereference. Every record that lives on a
  # timeline points back at it this way (+message.timeline+, +endpoint.timeline+, ...).
  # Fetch the full record when you need it.
  class Reference < ApiObject
    attribute :uuid
  end
end
