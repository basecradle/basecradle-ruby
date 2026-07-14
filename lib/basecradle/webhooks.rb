# frozen_string_literal: true

require_relative "api_object"
require_relative "items"

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

  # An inbound webhook URL on a timeline. Endpoints belong to the timeline, not a user,
  # so there is no +user+ block. Verbs update this object from the full endpoint the API
  # returns (live objects).
  class WebhookEndpoint < ApiObject
    attribute :type
    attribute :created_at
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

    # Live-object update: the API returned the complete endpoint; adopt it in place.
    def adopt(response)
      to_h.replace(response.fetch("webhook_endpoint"))
      self
    end
  end

  # One inbound delivery: what was sent, and on which (possibly retired) ingest URL.
  class WebhookEventContent < ApiObject
    attribute :uuid
    attribute :content_type
    attribute :headers
    attribute :payload # the raw request body, exactly as delivered
    attribute :ingest_token_at_receipt
  end

  # One inbound delivery to a webhook endpoint. Read-only — produced by external senders.
  class WebhookEvent < ApiObject
    attribute :type
    attribute :created_at
    attribute :timeline, wrap: Reference
    attribute :webhook_endpoint, wrap: Reference # the event's direct container
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

    def initialize(client, timeline_uuid)
      @client = client
      @timeline_uuid = timeline_uuid
    end

    # Create an inbound webhook endpoint on this timeline (viewer; the timeline unlocked).
    #
    # +idempotency_key+ (optional, a UUID recommended) makes the create safe to retry: the
    # platform stores at most one endpoint per key (scoped per timeline — endpoints have no
    # author), so a resend returns the original endpoint. See +BaseCradle::Client#max_retries+.
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

    def initialize(client, timeline_uuid)
      @client = client
      @timeline_uuid = timeline_uuid
    end

    def each(&block)
      WebhookEventsResource.new(@client).filter(timeline: @timeline_uuid).each(&block)
    end
  end
end
