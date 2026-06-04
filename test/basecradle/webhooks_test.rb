# frozen_string_literal: true

require "test_helper"

class WebhooksTest < Minitest::Test
  include TestSupport

  def setup
    @bc = BaseCradle::Client.new(FAKE_TOKEN)
  end

  # --- models -----------------------------------------------------------------------------

  def test_endpoint_model_reads_content_and_verification
    stub_request(:get, "#{BASE_URL}/webhook_endpoints").to_return(
      status: 200,
      body: { "webhook_endpoints" => [ webhook_endpoint_payload ], "next_cursor" => nil }.to_json
    )

    endpoint = @bc.webhook_endpoints.first

    assert_instance_of BaseCradle::WebhookEndpoint, endpoint
    assert_equal INGEST_URL, endpoint.content.ingest_url
    assert_equal "hmac_sha256_hex", endpoint.content.verification.verifier
    assert_instance_of BaseCradle::Reference, endpoint.timeline
  end

  def test_event_model_is_read_only_content
    stub_request(:get, "#{BASE_URL}/webhook_events").to_return(
      status: 200,
      body: { "webhook_events" => [ webhook_event_payload ], "next_cursor" => nil }.to_json
    )

    event = @bc.webhook_events.first

    assert_instance_of BaseCradle::WebhookEvent, event
    assert_equal '{"status":"ok"}', event.content.payload
    assert_equal WEBHOOK_ENDPOINT_UUID, event.webhook_endpoint.uuid
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
