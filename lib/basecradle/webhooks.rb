# frozen_string_literal: true

require_relative "api_object"
require_relative "items"
require_relative "rendering"
require_relative "serialization"
require_relative "user"

module BaseCradle
  # --- models ---------------------------------------------------------------------------

  # Whether inbound deliveries must be signed, and how.
  class WebhookVerification < ApiObject
    attribute :enabled
    attribute :signature_header
    attribute :verifier # "hmac_sha256_hex"
  end

  # An endpoint's content: identity, state, and the rotatable ingest URL.
  class WebhookEndpointContent < ApiObject
    attribute :uuid # the endpoint's stable identity — never changes
    attribute :description
    attribute :enabled
    attribute :ingest_url # the secret URL external senders POST to — rotatable
    attribute :verification, wrap: WebhookVerification
  end

  # An inbound webhook URL on a timeline. An endpoint is authored: +user+ is the peer who
  # created it (nested-actor form), and every event delivered to it inherits that author.
  # Verbs update this object from the full endpoint the API returns (live objects).
  #
  # The endpoint's identity is +content.uuid+ — the wire carries no top-level +uuid+, and
  # the SDK does not invent one. +BaseCradle.uuid_of(endpoint)+ yields it too, which is
  # what +bc.webhook_events.filter(endpoint:)+ uses.
  class WebhookEndpoint < ApiObject
    attribute :type
    attribute :created_at
    attribute :updated_at
    attribute :user, wrap: User # the endpoint's author
    attribute :timeline, wrap: Reference
    attribute :content, wrap: WebhookEndpointContent

    # Soft-stop: refuse inbound deliveries (410 Gone) until re-enabled. The endpoint and
    # its event history are kept; reversible via enable.
    def disable
      adopt(require_client.request("DELETE", enablement_path))
    end

    # Re-enable a disabled endpoint — inbound deliveries are accepted again.
    def enable
      adopt(require_client.request("POST", enablement_path))
    end

    # Regenerate the ingest URL. The old URL dies immediately; the uuid is unchanged.
    # Use this when an ingest URL leaks. Recorded events are preserved.
    def rotate
      adopt(require_client.request("POST", "/webhook_endpoints/#{content.uuid}/rotation"))
    end

    private

    def enablement_path
      "/webhook_endpoints/#{content.uuid}/enablement"
    end

    # Live-object update: the API returned the complete endpoint, so this object points at
    # it from here on. It re-points rather than overwriting the hash it was built from,
    # because that hash may belong to something else: an endpoint read off a WebhookEvent
    # is the event's own payload, and rewriting it would falsify the event's record of the
    # (possibly since-retired) ingest URL that delivery arrived on.
    def adopt(response)
      @data = response.fetch("webhook_endpoint")
      self
    end
  end

  # One delivery's request headers: the wire's own spelling, looked up case-insensitively.
  #
  # A +Hash+ of exactly what the wire carried — one pair per header, +Content-Type+ and
  # +Content-Length+ included — so iterating, +keys+, +to_h+, +to_json+ and +==+ all read
  # the platform's own spelling and nothing is renamed. Only *lookup* folds case, because
  # header names are case-insensitive by RFC and the platform does not preserve the
  # sender's casing: it stores names canonicalized to Title-Case per segment
  # (+X-Github-Delivery+, not +X-GitHub-Delivery+). So a vendor's published spelling finds
  # the header it names, and so does any other casing of it:
  #
  #   event.content.headers["X-GitHub-Delivery"] # GitHub's own published spelling
  #   event.content.headers["x-github-delivery"] # the lowercase form
  #   event.content.headers["X-Github-Delivery"] # what the wire actually carried
  #
  # Every read that takes a header name folds: +fetch+, +dig+, +values_at+, +fetch_values+,
  # +to_proc+ and +key?+ (with +has_key?+, +include?+ and +member?+). A header that was
  # genuinely not delivered is *absent*, never +nil+ — +[]+ and a fallback-less +fetch+ or
  # +fetch_values+ raise +KeyError+ naming the headers that did arrive, while +fetch+ with
  # a fallback, +dig+ and +values_at+ answer for it the way +Hash+ does.
  #
  # The methods that *reshape* the hash rather than read one name — +slice+, +except+,
  # +select+, +transform_values+ — and the mutators are left exactly as +Hash+ defines
  # them: case-sensitive, on the platform's own spelling. This is a read of one delivery
  # that already happened. Converting away from this type gives up the folding too
  # (+to_h+, <tt>{**headers}</tt>, and anything else that hands back a plain +Hash+);
  # +merge+ and +dup+ keep it.
  #
  # What it does *not* print is the values: +inspect+, +to_s+ and +pp+ render the header
  # names alone, because these are the sender's headers and one of them may be the
  # sender's credential. Every read is unaffected — and so is +to_json+, which still
  # emits the delivery verbatim. Converting away from this type gives the redaction up
  # exactly as it gives up the folding, and for the same reason: +slice+, +except+,
  # +select+, +transform_values+ and +to_h+ hand back a plain +Hash+, whose +inspect+
  # prints pairs.
  class WebhookEventHeaders < Hash
    # Hash's own exact-match membership, kept under a private name before the case-folding
    # +key?+ below takes the name: a caller who wrote the wire's own spelling is answered
    # without a scan, and it is the tiebreak if a derived copy holds two casings of one
    # name.
    alias_method :exact_key?, :key?
    private :exact_key?

    NO_FALLBACK = Object.new.freeze
    private_constant :NO_FALLBACK

    # +client:+ is unused — headers carry no verbs — but every wrapped model is built with
    # it (see ApiObject.attribute's +wrap:+), so it is accepted.
    def initialize(data, client: nil)
      super()
      update(data)
    end

    # The header's value, matched case-insensitively. Raises +KeyError+ when no casing of
    # the name was delivered.
    def [](name)
      wire = wire_name(name)
      wire.nil? ? raise_missing(name) : super(wire)
    end

    # Hash-like: the value, or the fallback — a default argument, or a block, which is
    # handed the name as written — when the header was not delivered. With no fallback it
    # behaves like +[]+.
    def fetch(name, fallback = NO_FALLBACK, &block)
      wire = wire_name(name)
      return super(wire) if wire
      return yield(name) if block
      return fallback unless fallback.equal?(NO_FALLBACK)

      raise_missing(name)
    end

    # Did this delivery carry the header, under any casing?
    def key?(name)
      !wire_name(name).nil?
    end
    alias_method :has_key?, :key?
    alias_method :include?, :key?
    alias_method :member?, :key?

    # Ruby's nil-returning read, case folded: the value, or +nil+ for a header that was
    # not delivered.
    def dig(name, *rest)
      wire = wire_name(name)
      wire.nil? ? nil : super(wire, *rest)
    end

    # Several headers at once, folded the same way — +nil+ for one that was not delivered,
    # as +Hash+ answers for a key it has no value for.
    def values_at(*names)
      names.map { |name| dig(name) }
    end

    # As +values_at+, but a header that was not delivered raises, exactly as +fetch+ does.
    def fetch_values(*names, &block)
      names.map { |name| block ? fetch(name, &block) : fetch(name) }
    end

    # +&headers+ — a header name to its value, folded, +nil+ for one not delivered.
    def to_proc
      ->(name) { dig(name) }
    end

    private

    # The header *names* this delivery carried, and none of their values.
    #
    # +Hash+'s own +inspect+ prints every pair, and these headers are the *sender's*,
    # stored verbatim by the platform: a sender that authenticates its POST to an ingest
    # URL puts its credential in one of them, so +logger.debug(event.content.headers)+
    # would write another party's secret into our logs.
    #
    # Only the human-facing render changes. Every *read* is untouched and still
    # wire-exact: lookups, +fetch+, +each+, +keys+, +to_h+, +to_json+, +==+.
    #
    # Names are sorted by their string form — a derived copy can hold a key that never
    # came off the wire, and a mixed-type +keys+ has no natural order otherwise.
    #
    # +nil+ for a delivery the platform recorded with no headers at all, so it renders as
    # the bare class. That is asked of the hash, not of the joined string: a delivery
    # carrying a single header whose *name* is the empty string joins to "" and must stay
    # distinguishable from one carrying nothing.
    def render_body
      return nil if empty?

      keys.sort_by(&:to_s).join(", ")
    end

    # The wire's own spelling of +name+, or nil if no casing of it was delivered. Anything
    # but a String is not a header name, so it is never matched rather than being coerced
    # into one: +headers[:host]+ finds nothing, and so misses like any other absent name.
    # Keys are type-checked too — +merge+ hands back one of these, so a caller's derived
    # copy can hold a key that never came off the wire.
    def wire_name(name)
      return nil unless name.is_a?(String)
      return name if exact_key?(name)

      each_key { |wire| return wire if wire.is_a?(String) && wire.casecmp?(name) }
      nil
    end

    def raise_missing(name)
      raise KeyError.new(
        "No #{name.inspect} header on this delivery. Header names are matched " \
        "case-insensitively, so no casing of it was delivered either. " \
        "Headers present: #{keys.sort_by(&:to_s).inspect}",
        receiver: self, key: name
      )
    end
  end

  # One inbound delivery: what was sent, and the two facts about the endpoint as it was at
  # the moment of receipt. Everything in the event's embedded endpoint is *current*; these
  # two are historical, and they are the only ones.
  #
  # +headers+ is the delivery's request headers as a +WebhookEventHeaders+ — the wire's
  # own pairs, looked up case-insensitively. This is the content model every read of the
  # record returns, +timeline.items+ included: a +webhook_event+ row's +content+ is one of
  # these (TimelineItem types content by the item's +type+), so the folding lookup is
  # there too. What gives it up is converting away from the type — +content["headers"]+,
  # ApiObject's raw-wire escape hatch, which wraps nothing, and the conversions
  # WebhookEventHeaders names above (+to_h+ and friends) all hand back a plain,
  # case-sensitive Hash.
  class WebhookEventContent < ApiObject
    attribute :uuid
    attribute :content_type
    attribute :headers, wrap: WebhookEventHeaders
    attribute :payload # the raw request body, exactly as delivered
    # The ingest token this delivery arrived on. Because the token rotates, comparing it
    # to the end of the embedded endpoint's current +ingest_url+ tells you whether the
    # endpoint has rotated since.
    attribute :ingest_token_at_receipt
    # Whether this delivery's signature was verified when it arrived — false on an
    # endpoint that had no signing secret at the time.
    attribute :verified_at_receipt
  end

  # One inbound delivery to a webhook endpoint. Read-only — produced by external senders,
  # so an event has no author.
  class WebhookEvent < ApiObject
    attribute :type
    attribute :created_at
    attribute :updated_at
    attribute :timeline, wrap: Reference
    # The endpoint this arrived on, embedded in full (its own subject form) rather than by
    # reference — so its current state reads without a second request, and its verbs
    # (disable / enable / rotate) are reachable straight off the event. Its uuid is
    # +event.webhook_endpoint.content.uuid+, or +BaseCradle.uuid_of(...)+.
    attribute :webhook_endpoint, wrap: WebhookEndpoint
    attribute :content, wrap: WebhookEventContent
  end

  # --- cross-timeline lists -------------------------------------------------------------

  # Webhook endpoints from every timeline you can view, newest first.
  class WebhookEndpointsResource < ItemsResource
    PATH = "/webhook_endpoints"
    PLURAL = "webhook_endpoints"
    SINGULAR = "webhook_endpoint"
    MODEL = WebhookEndpoint
  end

  # Webhook events from every timeline you can view, newest first (read-only).
  class WebhookEventsResource < ItemsResource
    PATH = "/webhook_events"
    PLURAL = "webhook_events"
    SINGULAR = "webhook_event"
    MODEL = WebhookEvent

    # Narrow by timeline and/or endpoint (a WebhookEndpoint or a uuid).
    def filter(timeline: nil, endpoint: nil)
      self.class.new(@client, filters: merge_filters(timeline: timeline, endpoint: endpoint))
    end
  end

  # --- nested resources on a Timeline ---------------------------------------------------

  # One timeline's webhook endpoints: create here, or iterate (newest first).
  class TimelineWebhookEndpoints
    include Enumerable
    include NotSerializableCollection

    def initialize(client, timeline_uuid)
      @client = client
      @timeline_uuid = timeline_uuid
    end

    # Create an inbound webhook endpoint on this timeline (viewer; the timeline unlocked).
    #
    # +idempotency_key+ (optional, a UUID recommended) makes the create safe to retry: the
    # platform stores at most one endpoint per key — scoped per timeline and author, like
    # the other three creates — so a resend returns the original endpoint. See
    # +BaseCradle::Client#max_retries+.
    def create(description:, idempotency_key: nil)
      response = @client.request("POST", "/timelines/#{@timeline_uuid}/webhook_endpoints",
                                 json: { "webhook_endpoint" => { "description" => description } },
                                 headers: BaseCradle.idempotency_headers(idempotency_key))
      WebhookEndpoint.new(response.fetch("webhook_endpoint"), client: @client)
    end

    def each(&block)
      WebhookEndpointsResource.new(@client).filter(timeline: @timeline_uuid).each(&block)
    end
  end

  # One timeline's webhook events — read-only, so iterate is all there is.
  class TimelineWebhookEvents
    include Enumerable
    include NotSerializableCollection

    def initialize(client, timeline_uuid)
      @client = client
      @timeline_uuid = timeline_uuid
    end

    def each(&block)
      WebhookEventsResource.new(@client).filter(timeline: @timeline_uuid).each(&block)
    end
  end
end
