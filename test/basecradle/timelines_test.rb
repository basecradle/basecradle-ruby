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
    item = { "type" => "message", "created_at" => "2026-01-02T00:00:00.000Z",
             "user" => NOVA, "content" => { "uuid" => "m1", "body" => "hi" } }
    stub_request(:get, "#{BASE_URL}/timelines/#{TIMELINE_UUID}")
      .to_return(status: 200, body: { "timeline" => timeline_payload, "items" => [ item ] }.to_json)

    timeline = @bc.timelines.get(TIMELINE_UUID)

    assert_instance_of BaseCradle::User, timeline.owner
    assert_equal "john", timeline.owner.handle
    assert_equal [ "nova" ], timeline.participants.map(&:handle)
    assert_instance_of BaseCradle::TimelineItem, timeline.items.first
    assert_equal "nova", timeline.items.first.user.handle
  end

  # --- verbs (live objects) --------------------------------------------------------------

  def test_lock_updates_locked_in_place
    timeline = fetch_timeline
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/lock")
      .to_return(status: 200, body: { "uuid" => TIMELINE_UUID, "locked" => true }.to_json)

    refute timeline.locked
    assert_same timeline, timeline.lock
    assert timeline.locked
  end

  def test_add_participant_accepts_a_uuid_and_appends_the_returned_user
    timeline = fetch_timeline(participants: [])
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/participations")
      .to_return(status: 201, body: NOVA.to_json)

    added = timeline.add_participant(NOVA["uuid"])

    assert_instance_of BaseCradle::User, added
    assert_equal "nova", added.handle
    assert_equal [ "nova" ], timeline.participants.map(&:handle)
    assert_requested(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/participations") do |req|
      JSON.parse(req.body) == { "user_id" => NOVA["uuid"] }
    end
  end

  def test_add_participant_accepts_a_user_object_and_is_idempotent
    timeline = fetch_timeline(participants: [])
    nova = BaseCradle::User.new(NOVA)
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/participations")
      .to_return(status: 201, body: NOVA.to_json)

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

  # --- a list row carries no items -------------------------------------------------------

  def test_list_rows_have_no_items_so_reading_items_raises
    stub_request(:get, "#{BASE_URL}/timelines")
      .to_return(status: 200,
                 body: { "timelines" => [ timeline_payload ], "next_cursor" => nil }.to_json)

    assert_raises(BaseCradle::MissingFieldError) { @bc.timelines.first.items }
  end
end
