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
    # The header deliveries are checked against: the signature's under "hmac_sha256_hex",
    # the secret's under "shared_secret_header". A "github" endpoint reports its fixed
    # X-Hub-Signature-256 here; a "slack" endpoint always reads X-Slack-Signature, a
    # "stripe" endpoint Stripe-Signature, and a "twilio" endpoint X-Twilio-Signature. An
    # "sns" endpoint reports an empty string: SNS signs inside the message, so no header
    # is read.
    attribute :signature_header
    # "hmac_sha256_hex", "github", "shared_secret_header", "slack", "stripe", "twilio" or
    # "sns" today — an open set; read it as a string.
    attribute :verifier
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
    # - +verifier+ is the scheme, one of seven today: "hmac_sha256_hex" (the default; any
    #   sender you control signs the body), "github" (a GitHub webhook),
    #   "shared_secret_header" (a sender that cannot sign sends the secret itself in a
    #   header), "slack" (a Slack app's Events API; the endpoint answers Slack's
    #   url_verification handshake itself, and the handshake creates no event), "stripe"
    #   (a Stripe webhook destination; a delivery whose signed timestamp is more than five
    #   minutes from now is refused, and a repeat of one Stripe event, the same event id,
    #   is stored once), "twilio" (the webhooks Twilio sends: an incoming text message, a
    #   recording or transcription callback, a status callback) or "sns" (an Amazon SNS
    #   topic's HTTPS subscription, in a standard or GovCloud region, not China; the
    #   endpoint confirms the subscription itself, and the confirmation creates no event,
    #   so set the topic's ARN before subscribing it, since with no ARN set the
    #   confirmation is stored as an event whose SubscribeURL is yours to open; raw message
    #   delivery must be off; a repeat of one SNS message, the same MessageId, is stored
    #   once). It is passed through as given, so a scheme the platform adds later
    #   works here unchanged; one it does not know raises ValidationError. Twilio signs the
    #   URL it was given, so give it +content.ingest_url+ exactly as the endpoint reports
    #   it. Twilio also reads the reply, so a "twilio" endpoint answers each delivery it
    #   stores with 200 OK and an empty TwiML document in place of the empty 201: the
    #   answer to the sender, which changes nothing this method returns. That empty answer
    #   ends a voice call, so the ingest_url is never a number's voice URL; point a
    #   recording's callbacks at it instead.
    # - +credential+ is the signing secret, sent as +verification_credential+: setting it
    #   turns verification on. Under "shared_secret_header" nothing is signed: it is the
    #   header's exact value, compared as sent, so include any prefix the sender adds.
    #   Under "stripe" it is the destination's Signing secret at Stripe (whsec_...), not an
    #   API key. Under "sns" it is the ARN of the topic the endpoint listens to: not a
    #   secret, and still write-only. Pass it in the same call that moves an endpoint to
    #   or from "sns": a topic's ARN is never carried over to a secret scheme, nor a secret
    #   to "sns", so passing only +verifier+ there raises ValidationError. That rule binds
    #   only an endpoint that holds a credential: one with none moves between any two
    #   schemes freely. So to move an endpoint off "sns" before the new sender's secret
    #   exists, call clear_verification first, then name the new scheme here. From the
    #   first call until the new secret is set, the endpoint holds no credential, so, like
    #   any endpoint with none, it accepts deliveries without proof: disable it first and
    #   enable it once the secret is set to refuse them in the meantime.
    #   Under "twilio" it is a shared key made at Twilio for signing webhooks (Twilio's own
    #   recommendation) or the account's Auth Token. An endpoint holds one secret, a
    #   delivery signed with the other is refused with 401, and Twilio does not resend it
    #   by default: when you switch between the two, or replace a shared key, change it
    #   here in the same minute you change it at Twilio. A blank credential is sent as
    #   given and the API treats it as no change: the current secret, if any, stays, and
    #   +content.verification.enabled+ cannot tell that skipped rotation from a real one,
    #   so make sure a secret read from the environment is not empty before passing it. It
    #   is sent as its bytes, which must be UTF-8 (a BINARY string read from a file is
    #   fine); a credential that is not a String, or whose bytes are not UTF-8, raises
    #   ArgumentError before any request, and the error never shows it. It is write-only:
    #   the API never returns it, and this SDK keeps no copy and never puts it in an
    #   inspect or an error message.
    # - +signature_header+ is the header that is read: the signature's under
    #   "hmac_sha256_hex", the secret's under "shared_secret_header". A "github", "slack",
    #   "sns", "stripe" or "twilio" endpoint ignores it. Pass it in the same call that
    #   moves an endpoint to "shared_secret_header", or from it back to "hmac_sha256_hex":
    #   a header named for one is never carried over to the other, so passing only
    #   +verifier+ there raises ValidationError. A move from "shared_secret_header" to
    #   "github", "slack", "sns", "stripe" or "twilio" that names no header resets it to
    #   X-Signature.
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
      given["verification_credential"] = sendable_secret(credential) unless credential.nil?

      adopt(require_client.request("PATCH", endpoint_path, json: { "webhook_endpoint" => given }))
    end

    # Remove the signing secret and turn verification off: deliveries are accepted
    # unsigned again, and +content.verification.enabled+ reads false. The verifier
    # stays: an endpoint with no credential moves between any two schemes freely, so this,
    # then configure_verification(verifier: ...), moves an endpoint off "sns" before the
    # new sender's secret exists. From this call until the new secret is set, the
    # endpoint, like any endpoint with no credential, accepts deliveries without proof:
    # disable it first and enable it once the secret is set to refuse them in the
    # meantime. Returns this endpoint, which adopts the one the API returns.
    def clear_verification
      adopt(require_client.request("PATCH", endpoint_path,
                                   json: { "webhook_endpoint" => { "clear_credential" => true } }))
    end

    private

    # The credential's bytes as given, read as UTF-8, or ArgumentError. JSON refuses a
    # string it cannot read as UTF-8, and its error holds the whole string, so a secret
    # with the wrong bytes would ride out on an exception's +invalid_object+. Refusing it
    # here, with a message that names the fault and never the value, closes that door.
    def sendable_secret(credential)
      if credential.is_a?(String)
        secret = credential.b.force_encoding(Encoding::UTF_8)
        return secret if secret.valid_encoding?
      end

      raise ArgumentError, "credential: must be a String whose bytes are UTF-8. It is not shown. " \
                           "Nothing was sent."
    end

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
    include PaginatedList

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

    private

    def list
      WebhookEndpointsResource.new(@client).filter(timeline: @timeline_uuid)
    end
  end

  # One timeline's webhook events — read-only, so iterate is all there is.
  class TimelineWebhookEvents
    include Enumerable
    include PaginatedList

    def initialize(client, timeline_uuid)
      @client = client
      @timeline_uuid = timeline_uuid
    end

    private

    def list
      WebhookEventsResource.new(@client).filter(timeline: @timeline_uuid)
    end
  end
end
