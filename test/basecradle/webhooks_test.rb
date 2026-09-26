# frozen_string_literal: true

require "test_helper"

class WebhooksTest < Minitest::Test
  include TestSupport

  def setup
    @bc = BaseCradle::Client.new(FAKE_TOKEN)
  end

  # --- models -----------------------------------------------------------------------------

  def test_endpoint_model_reads_its_author_content_and_verification
    stub_request(:get, "#{BASE_URL}/webhook_endpoints").to_return(
      status: 200,
      body: { "webhook_endpoints" => [ webhook_endpoint_payload ], "next_cursor" => nil }.to_json
    )

    endpoint = @bc.webhook_endpoints.first

    assert_instance_of BaseCradle::WebhookEndpoint, endpoint
    assert_equal INGEST_URL, endpoint.content.ingest_url
    assert_equal "hmac_sha256_hex", endpoint.content.verification.verifier
    assert_instance_of BaseCradle::Reference, endpoint.timeline
    # An endpoint is authored: user is the peer who created it, in nested-actor form.
    assert_instance_of BaseCradle::User, endpoint.user
    assert_equal "john", endpoint.user.handle
    assert_equal "2026-01-02T00:00:00.000Z", endpoint.updated_at
  end

  # An endpoint has no top-level uuid on the wire, and the SDK invents none: its identity
  # is content.uuid, which BaseCradle.uuid_of reads (that is what .filter uses).
  def test_endpoint_identity_is_content_uuid
    endpoint = an_endpoint

    assert_equal WEBHOOK_ENDPOINT_UUID, endpoint.content.uuid
    assert_equal WEBHOOK_ENDPOINT_UUID, BaseCradle.uuid_of(endpoint)
    refute_respond_to endpoint, :uuid
  end

  def test_event_model_is_read_only_content_with_the_two_receipt_facts
    stub_request(:get, "#{BASE_URL}/webhook_events").to_return(
      status: 200,
      body: { "webhook_events" => [ webhook_event_payload ], "next_cursor" => nil }.to_json
    )

    event = @bc.webhook_events.first

    assert_instance_of BaseCradle::WebhookEvent, event
    assert_equal '{"status":"ok"}', event.content.payload
    # The SDK passes the headers hash through untouched, so the keys are the platform's
    # canonical Title-Case names — one pair per header as sent, Content-Type and
    # Content-Length included. (The platform canonicalizes; a sender's own casing is not
    # preserved, so "X-Github-Delivery" is the key even when GitHub wrote "X-GitHub-...".)
    assert_equal "ping", event.content.headers["X-Example-Event"]
    assert_equal "application/json", event.content.headers["Content-Type"]
    assert_equal "15", event.content.headers["Content-Length"] # tracks the payload
    assert_equal "2026-01-02T00:00:00.000Z", event.updated_at
    assert_instance_of BaseCradle::Reference, event.timeline
    # The event's two historical facts about the delivery, fixed at receipt.
    assert_equal "019e7750-66ee-705a-803c-b25c5ee9b1f3", event.content.ingest_token_at_receipt
    refute event.content.verified_at_receipt
  end

  def test_event_verified_at_receipt_reads_a_signed_delivery
    stub_request(:get, "#{BASE_URL}/webhook_events").to_return(
      status: 200,
      body: { "webhook_events" => [ webhook_event_payload(verified_at_receipt: true) ],
              "next_cursor" => nil }.to_json
    )

    assert @bc.webhook_events.first.content.verified_at_receipt
  end

  # An event embeds its endpoint in full, so the endpoint's *current* state reads without
  # a second request — and it is a live endpoint, not a dead reference.
  def test_event_reads_its_embedded_endpoint_and_keeps_its_verbs_reachable
    stub_request(:get, "#{BASE_URL}/webhook_events").to_return(
      status: 200,
      body: { "webhook_events" => [ webhook_event_payload ], "next_cursor" => nil }.to_json
    )
    stub_request(:post, "#{BASE_URL}/webhook_endpoints/#{WEBHOOK_ENDPOINT_UUID}/rotation")
      .to_return(status: 200, body: { "webhook_endpoint" => webhook_endpoint_payload }.to_json)

    endpoint = @bc.webhook_events.first.webhook_endpoint

    assert_instance_of BaseCradle::WebhookEndpoint, endpoint
    assert_equal WEBHOOK_ENDPOINT_UUID, endpoint.content.uuid
    assert_equal INGEST_URL, endpoint.content.ingest_url
    assert_equal "john", endpoint.user.handle # the author rides along
    assert_equal WEBHOOK_ENDPOINT_UUID, BaseCradle.uuid_of(endpoint) # so .filter still works

    endpoint.rotate # a verb, reachable because the event's client came with it

    assert_requested(:post, "#{BASE_URL}/webhook_endpoints/#{WEBHOOK_ENDPOINT_UUID}/rotation")
  end

  # An event is a permanent record of one delivery, so acting on the endpoint it embeds
  # must not rewrite it — the event still says which (now retired) ingest URL was live.
  def test_rotating_an_endpoint_read_off_an_event_leaves_the_event_untouched
    rotated_url = "#{BASE_URL}/webhooks/019e7750-66ee-7bd1-9cf4-0b2a6b5b0f4a"
    stub_request(:get, "#{BASE_URL}/webhook_events").to_return(
      status: 200,
      body: { "webhook_events" => [ webhook_event_payload ], "next_cursor" => nil }.to_json
    )
    stub_request(:post, "#{BASE_URL}/webhook_endpoints/#{WEBHOOK_ENDPOINT_UUID}/rotation")
      .to_return(status: 200,
                 body: { "webhook_endpoint" =>
                         webhook_endpoint_payload(ingest_url: rotated_url) }.to_json)

    event = @bc.webhook_events.first
    endpoint = event.webhook_endpoint
    endpoint.rotate

    assert_equal rotated_url, endpoint.content.ingest_url # the endpoint is live
    assert_equal INGEST_URL, event.webhook_endpoint.content.ingest_url # the record is not
  end

  # --- verbs (live objects, addressed by content.uuid) ------------------------------------

  def test_create_posts_description_and_returns_endpoint
    timeline = fetch_timeline
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/webhook_endpoints")
      .to_return(status: 201, body: { "webhook_endpoint" => webhook_endpoint_payload }.to_json)

    endpoint = timeline.webhook_endpoints.create(description: "CI notifications")

    assert_instance_of BaseCradle::WebhookEndpoint, endpoint
    assert_requested(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/webhook_endpoints") do |req|
      JSON.parse(req.body) == { "webhook_endpoint" => { "description" => "CI notifications" } }
    end
  end

  def test_create_sends_the_idempotency_key_header_when_given
    timeline = fetch_timeline
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/webhook_endpoints")
      .to_return(status: 201, body: { "webhook_endpoint" => webhook_endpoint_payload }.to_json)

    timeline.webhook_endpoints.create(description: "CI notifications",
                                      idempotency_key: "019f5e48-87c6-7d1e-9a48-7a701e8bd5bb")

    assert_requested(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/webhook_endpoints") do |req|
      req.headers["Idempotency-Key"] == "019f5e48-87c6-7d1e-9a48-7a701e8bd5bb"
    end
  end

  def test_disable_hits_enablement_and_adopts_the_returned_endpoint
    endpoint = an_endpoint
    stub_request(:delete, "#{BASE_URL}/webhook_endpoints/#{WEBHOOK_ENDPOINT_UUID}/enablement")
      .to_return(status: 200,
                 body: { "webhook_endpoint" => webhook_endpoint_payload(enabled: false) }.to_json)

    assert_same endpoint, endpoint.disable
    refute endpoint.content.enabled
  end

  def test_enable_hits_enablement
    endpoint = an_endpoint(enabled: false)
    stub_request(:post, "#{BASE_URL}/webhook_endpoints/#{WEBHOOK_ENDPOINT_UUID}/enablement")
      .to_return(status: 200,
                 body: { "webhook_endpoint" => webhook_endpoint_payload(enabled: true) }.to_json)

    endpoint.enable

    assert endpoint.content.enabled
  end

  def test_rotate_replaces_the_ingest_url_keeping_the_uuid
    endpoint = an_endpoint
    new_url = "#{BASE_URL}/webhooks/019e7750-66ee-7000-aaaa-000000000000"
    stub_request(:post, "#{BASE_URL}/webhook_endpoints/#{WEBHOOK_ENDPOINT_UUID}/rotation")
      .to_return(status: 200,
                 body: { "webhook_endpoint" => webhook_endpoint_payload(ingest_url: new_url) }.to_json)

    endpoint.rotate

    assert_equal new_url, endpoint.content.ingest_url
    assert_equal WEBHOOK_ENDPOINT_UUID, endpoint.content.uuid # unchanged
  end

  # --- filtering --------------------------------------------------------------------------

  def test_events_filter_by_endpoint_object_uses_content_uuid
    endpoint = an_endpoint
    stub_request(:get, "#{BASE_URL}/webhook_events")
      .with(query: { "endpoint" => WEBHOOK_ENDPOINT_UUID })
      .to_return(status: 200,
                 body: { "webhook_events" => [ webhook_event_payload ], "next_cursor" => nil }.to_json)

    @bc.webhook_events.filter(endpoint: endpoint).to_a

    assert_requested(:get, "#{BASE_URL}/webhook_events",
                     query: { "endpoint" => WEBHOOK_ENDPOINT_UUID })
  end

  def test_timeline_webhook_events_are_iterable_and_read_only
    timeline = fetch_timeline
    stub_request(:get, "#{BASE_URL}/webhook_events").with(query: { "timeline" => TIMELINE_UUID })
      .to_return(status: 200,
                 body: { "webhook_events" => [ webhook_event_payload ], "next_cursor" => nil }.to_json)

    assert_equal 1, timeline.webhook_events.to_a.size
    refute_respond_to timeline.webhook_events, :create
  end

  private

  def fetch_timeline
    stub_request(:get, "#{BASE_URL}/timelines/#{TIMELINE_UUID}")
      .to_return(status: 200, body: { "timeline" => timeline_payload, "items" => [] }.to_json)
    @bc.timelines.get(TIMELINE_UUID)
  end

  def an_endpoint(**overrides)
    BaseCradle::WebhookEndpoint.new(webhook_endpoint_payload(**overrides), client: @bc)
  end
end
