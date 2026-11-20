# frozen_string_literal: true

require_relative "api_object"
require_relative "headers"
require_relative "items"
require_relative "serialization"
require_relative "user"

module BaseCradle
  # --- models ---------------------------------------------------------------------------

  # Whether inbound deliveries must be signed, and how.
  #
  # +enabled+ is true once a signing secret is set. The secret itself is write-only: the
  # API never returns it, so it is never here. Set it, the scheme and the header with
  # +endpoint.configure_verification+; turn verification off with
  # +endpoint.clear_verification+.
  class WebhookVerification < ApiObject
    attribute :enabled
    attribute :signature_header # for a "github" endpoint, always "X-Hub-Signature-256"
    attribute :verifier # "hmac_sha256_hex" or "github" — an open set; read it as a string
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
  # Verbs update this object from the full endpoint the API returns (live objects). The
  # API models enablement and rotation as singular state resources, and signature
  # verification as a +PATCH+ of the endpoint itself; the SDK expresses all of them as
  # verbs here, never as raw paths.
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
      adopt(require_client.request("POST", "#{endpoint_path}/rotation"))
    end

    # Set how inbound deliveries must be signed: the scheme, the secret, the header.
    #
    # Every keyword is optional and only the ones you pass are sent, so anything left out
    # stays as it is; pass at least one, or this raises ArgumentError before any request
    # is made.
    #
    # - +verifier+ is the scheme: "hmac_sha256_hex" (the default) or "github". It is
    #   passed through as given, so a scheme the platform adds later works here unchanged;
    #   one it does not know raises ValidationError.
    # - +credential+ is the signing secret, sent as +verification_credential+: setting it
    #   turns verification on. A blank one is sent as given and the API treats it as no
    #   change: the current secret, if any, stays, and +content.verification.enabled+
    #   cannot tell that skipped rotation from a real one, so make sure a secret read from
    #   the environment is not empty before passing it. It is write-only: the API never
    #   returns it, and this SDK keeps no copy and never puts it in an inspect or an error
    #   message.
    # - +signature_header+ is the header the signature is read from, for
    #   "hmac_sha256_hex" only; a "github" endpoint always reads X-Hub-Signature-256.
    #
    # Any viewer of the endpoint's timeline may configure it, locked timeline or not.
    # Returns this endpoint, which adopts the one the API returns, so
    # +content.verification+ shows the new state.
    def configure_verification(verifier: nil, credential: nil, signature_header: nil)
      given = { "verifier" => verifier, "verification_credential" => credential,
                "signature_header" => signature_header }.compact
      if given.empty?
        raise ArgumentError, "configure_verification needs at least one of verifier:, credential: " \
                             "or signature_header:. Nothing was sent."
      end

      adopt(require_client.request("PATCH", endpoint_path, json: { "webhook_endpoint" => given }))
    end

    # Remove the signing secret and turn verification off: deliveries are accepted
    # unsigned again, and +content.verification.enabled+ reads false. Returns this
    # endpoint, which adopts the one the API returns.
    def clear_verification
      adopt(require_client.request("PATCH", endpoint_path,
                                   json: { "webhook_endpoint" => { "clear_credential" => true } }))
    end

    private

    def endpoint_path
      "/webhook_endpoints/#{content.uuid}"
    end

    def enablement_path
      "#{endpoint_path}/enablement"
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

  # One delivery's request headers, exactly as the sender sent them — read through
  # RequestHeaders' rules: case-insensitive lookup, a render of names and never values.
  class WebhookEventHeaders < RequestHeaders; end

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
    # (disable / enable / rotate / configure_verification / clear_verification) are
    # reachable straight off the event. Its uuid is
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
    # A key HTTP cannot carry exactly as given raises ArgumentError before anything is
    # sent (see BaseCradle.idempotency_headers).
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
