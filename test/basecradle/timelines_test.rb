# frozen_string_literal: true

require "test_helper"

class TimelinesTest < Minitest::Test
  include TestSupport

  def setup
    @bc = BaseCradle::Client.new(FAKE_TOKEN)
  end

  # Stub GET /timelines/:uuid and return a fetched Timeline (participants default to [NOVA]).
  def fetch_timeline(participants: [ NOVA ], **overrides)
    stub_request(:get, "#{BASE_URL}/timelines/#{TIMELINE_UUID}").to_return(
      status: 200,
      body: { "timeline" => timeline_payload(participants: participants, **overrides),
              "items" => [] }.to_json
    )
    @bc.timelines.get(TIMELINE_UUID)
  end

  # Stub GET /timelines/:uuid returning one inline item.
  def stub_timeline_with(item)
    stub_request(:get, "#{BASE_URL}/timelines/#{TIMELINE_UUID}")
      .to_return(status: 200, body: { "timeline" => timeline_payload, "items" => [ item ] }.to_json)
  end

  # A webhook_event item: no author, and its endpoint embedded in full.
  def webhook_event_item
    event = webhook_event_payload
    item_payload("webhook_event", event["content"], user: nil)
      .merge("webhook_endpoint" => event["webhook_endpoint"])
  end

  # Stub POST /timelines/:uuid/participations with the {"user" => ...} envelope the API
  # returns — the added user in subject form.
  def stub_participation
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/participations")
      .to_return(status: 201, body: { "user" => directory_user_payload(user: NOVA) }.to_json)
  end

  # --- iteration & pagination ------------------------------------------------------------

  def test_iterates_timelines_newest_first
    stub_request(:get, "#{BASE_URL}/timelines")
      .to_return(status: 200, body: {
        "timelines" => [ timeline_payload(name: "A"), timeline_payload(name: "B") ],
        "next_cursor" => nil
      }.to_json)

    assert_equal %w[A B], @bc.timelines.map(&:name)
  end

  def test_pagination_is_invisible_and_follows_the_cursor
    # Page 1 (no cursor); the more-specific before=CURSOR1 stub wins for page 2.
    stub_request(:get, "#{BASE_URL}/timelines")
      .to_return(status: 200, body: {
        "timelines" => [ timeline_payload(name: "newest") ], "next_cursor" => "CURSOR1"
      }.to_json)
    stub_request(:get, "#{BASE_URL}/timelines").with(query: { "before" => "CURSOR1" })
      .to_return(status: 200, body: {
        "timelines" => [ timeline_payload(name: "older") ], "next_cursor" => nil
      }.to_json)

    assert_equal %w[newest older], @bc.timelines.map(&:name)
    assert_requested(:get, "#{BASE_URL}/timelines", query: { "before" => "CURSOR1" })
  end

  def test_iteration_is_lazy
    stub_request(:get, "#{BASE_URL}/timelines")
      .to_return(status: 200, body: {
        "timelines" => [ timeline_payload(name: "newest") ], "next_cursor" => "CURSOR1"
      }.to_json)

    # first stops after the first page — the second page is never fetched.
    assert_equal "newest", @bc.timelines.first.name
    assert_not_requested(:get, "#{BASE_URL}/timelines", query: { "before" => "CURSOR1" })
  end

  # --- create / get ----------------------------------------------------------------------

  def test_create_returns_a_timeline_from_the_two_key_envelope
    stub_request(:post, "#{BASE_URL}/timelines")
      .to_return(status: 201, body: { "timeline" => timeline_payload, "items" => [] }.to_json)

    timeline = @bc.timelines.create(name: "Incident response")

    assert_instance_of BaseCradle::Timeline, timeline
    assert_equal "Incident response", timeline.name
    assert_equal [], timeline.items
    assert_requested(:post, "#{BASE_URL}/timelines") do |req|
      JSON.parse(req.body) == { "timeline" => { "name" => "Incident response" } }
    end
  end

  def test_get_merges_items_inline_and_wraps_actors
    stub_timeline_with(message_payload(user: NOVA))

    timeline = @bc.timelines.get(TIMELINE_UUID)

    assert_instance_of BaseCradle::User, timeline.owner
    assert_equal "john", timeline.owner.handle
    assert_equal [ "nova" ], timeline.participants.map(&:handle)
    assert_instance_of BaseCradle::TimelineItem, timeline.items.first
    assert_equal "nova", timeline.items.first.user.handle
  end

  # An inline item is the record's own standalone form: same timeline reference and
  # updated_at as its own page, with created_at the moment it landed on the timeline.
  def test_an_inline_item_carries_its_timeline_reference_and_updated_at
    stub_timeline_with(message_payload)

    item = @bc.timelines.get(TIMELINE_UUID).items.first

    assert_instance_of BaseCradle::Reference, item.timeline
    assert_equal TIMELINE_UUID, item.timeline.uuid
    assert_equal "2026-01-02T00:00:00.000Z", item.updated_at
  end

  # A webhook_event item has no author, so the platform omits +user+ there. The rest of
  # the item reads normally; +user+ raises rather than inventing an author.
  def test_a_webhook_event_item_carries_no_user
    stub_timeline_with(webhook_event_item)

    event_item = @bc.timelines.get(TIMELINE_UUID).items.first

    assert_equal "webhook_event", event_item.type
    assert_equal '{"status":"ok"}', event_item.content["payload"]
    assert_raises(BaseCradle::MissingFieldError) { event_item.user }
  end

  # A webhook_event item embeds its endpoint in full, exactly as the event's own page
  # does — so it is a live endpoint, verbs and all, straight off the timeline.
  def test_a_webhook_event_item_embeds_its_endpoint_in_full
    stub_timeline_with(webhook_event_item)
    stub_request(:post, "#{BASE_URL}/webhook_endpoints/#{WEBHOOK_ENDPOINT_UUID}/rotation")
      .to_return(status: 200, body: { "webhook_endpoint" => webhook_endpoint_payload }.to_json)

    endpoint = @bc.timelines.get(TIMELINE_UUID).items.first.webhook_endpoint

    assert_instance_of BaseCradle::WebhookEndpoint, endpoint
    assert_equal WEBHOOK_ENDPOINT_UUID, endpoint.content.uuid
    assert_equal "john", endpoint.user.handle
    endpoint.rotate

    assert_requested(:post, "#{BASE_URL}/webhook_endpoints/#{WEBHOOK_ENDPOINT_UUID}/rotation")
  end

  # Only a webhook_event item carries an endpoint — on any other item reading it raises
  # rather than inventing one.
  def test_a_message_item_has_no_webhook_endpoint
    stub_timeline_with(message_payload)

    item = @bc.timelines.get(TIMELINE_UUID).items.first

    assert_raises(BaseCradle::MissingFieldError) { item.webhook_endpoint }
  end

  # --- verbs (live objects) --------------------------------------------------------------

  def test_lock_adopts_the_whole_returned_timeline
    timeline = fetch_timeline
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/lock").to_return(
      status: 200,
      body: { "timeline" => timeline_payload(locked: true,
                                             updated_at: "2026-01-03T00:00:00.000Z") }.to_json
    )

    refute timeline.locked
    assert_same timeline, timeline.lock
    assert timeline.locked
    # Not just `locked`: the whole subject form is adopted, like every other live-object verb.
    assert_equal "2026-01-03T00:00:00.000Z", timeline.updated_at
  end

  # The lock response is the timeline's subject form, which carries no inline items —
  # and locking freezes content rather than changing it, so the items we already read
  # must survive the adopt.
  def test_lock_keeps_the_items_the_timeline_was_fetched_with
    stub_timeline_with(message_payload)
    timeline = @bc.timelines.get(TIMELINE_UUID)
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/lock")
      .to_return(status: 200, body: { "timeline" => timeline_payload(locked: true) }.to_json)

    timeline.lock

    assert_equal 1, timeline.items.size
    assert_equal "message", timeline.items.first.type
  end

  # A list row has no items key, so there is none to carry across — and the adopt must
  # not invent one.
  def test_lock_on_a_list_row_leaves_items_unreadable
    stub_request(:get, "#{BASE_URL}/timelines")
      .to_return(status: 200,
                 body: { "timelines" => [ timeline_payload ], "next_cursor" => nil }.to_json)
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/lock")
      .to_return(status: 200, body: { "timeline" => timeline_payload(locked: true) }.to_json)

    timeline = @bc.timelines.first.lock

    assert timeline.locked
    assert_raises(BaseCradle::MissingFieldError) { timeline.items }
  end

  def test_add_participant_accepts_a_uuid_and_appends_the_user_from_the_envelope
    timeline = fetch_timeline(participants: [])
    stub_participation

    added = timeline.add_participant(NOVA["uuid"])

    assert_instance_of BaseCradle::User, added
    assert_equal "nova", added.handle
    assert_equal [ "nova" ], timeline.participants.map(&:handle)
    refute timeline.participants.first.trust.mutual # the subject form, rostered whole
    assert_requested(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/participations") do |req|
      JSON.parse(req.body) == { "user_id" => NOVA["uuid"] }
    end
  end

  def test_add_participant_accepts_a_user_object_and_is_idempotent
    timeline = fetch_timeline(participants: [])
    nova = BaseCradle::User.new(NOVA)
    stub_participation

    timeline.add_participant(nova)
    timeline.add_participant(nova)

    assert_equal 1, timeline.participants.size # no duplicate
  end

  def test_remove_participant_drops_it_locally
    timeline = fetch_timeline # participants: [NOVA]
    stub_request(:delete, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/participations/#{NOVA['uuid']}")
      .to_return(status: 204)

    assert_same timeline, timeline.remove_participant(NOVA["uuid"])
    assert_empty timeline.participants
  end

  def test_delete_returns_nil_on_204
    timeline = fetch_timeline
    stub_request(:delete, "#{BASE_URL}/timelines/#{TIMELINE_UUID}").to_return(status: 204)

    assert_nil timeline.delete
    assert_requested(:delete, "#{BASE_URL}/timelines/#{TIMELINE_UUID}")
  end

  def test_delete_of_a_locked_timeline_still_deletes
    timeline = fetch_timeline(locked: true)
    stub_request(:delete, "#{BASE_URL}/timelines/#{TIMELINE_UUID}").to_return(status: 204)

    # Locking freezes content, not governance — a locked timeline is still deletable.
    assert_nil timeline.delete
  end

  def test_delete_by_a_non_owner_raises_not_timeline_owner
    timeline = fetch_timeline
    stub_request(:delete, "#{BASE_URL}/timelines/#{TIMELINE_UUID}").to_return(
      status: 403,
      headers: { "Content-Type" => "application/problem+json" },
      body: { "code" => "not_timeline_owner", "status" => 403,
              "title" => "Forbidden", "detail" => "You do not own this timeline." }.to_json
    )

    error = assert_raises(BaseCradle::NotTimelineOwnerError) { timeline.delete }
    assert_equal "not_timeline_owner", error.code
    assert_equal 403, error.status
  end

  def test_delete_of_an_unknown_timeline_raises_not_found
    timeline = fetch_timeline
    stub_request(:delete, "#{BASE_URL}/timelines/#{TIMELINE_UUID}").to_return(
      status: 404,
      headers: { "Content-Type" => "application/problem+json" },
      body: { "code" => "not_found", "status" => 404, "title" => "Not Found",
              "detail" => "No such timeline." }.to_json
    )

    assert_raises(BaseCradle::NotFoundError) { timeline.delete }
  end

  # --- a list row carries no items -------------------------------------------------------

  def test_list_rows_have_no_items_so_reading_items_raises
    stub_request(:get, "#{BASE_URL}/timelines")
      .to_return(status: 200,
                 body: { "timelines" => [ timeline_payload ], "next_cursor" => nil }.to_json)

    assert_raises(BaseCradle::MissingFieldError) { @bc.timelines.first.items }
  end
end
