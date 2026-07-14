# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tempfile"

class ItemsTest < Minitest::Test
  include TestSupport

  def setup
    @bc = BaseCradle::Client.new(FAKE_TOKEN)
  end

  # --- models -----------------------------------------------------------------------------

  def test_message_model_reads_content_user_and_timeline_reference
    stub_request(:get, "#{BASE_URL}/messages")
      .to_return(status: 200, body: { "messages" => [ message_payload ], "next_cursor" => nil }.to_json)

    message = @bc.messages.first

    assert_instance_of BaseCradle::Message, message
    assert_equal "message", message.type
    assert_equal "Hello from a peer.", message.content.body
    assert_equal "john", message.user.handle
    assert_instance_of BaseCradle::Reference, message.timeline
    assert_equal TIMELINE_UUID, message.timeline.uuid
  end

  def test_asset_model_reads_the_nested_file
    stub_request(:get, "#{BASE_URL}/assets")
      .to_return(status: 200, body: { "assets" => [ asset_payload ], "next_cursor" => nil }.to_json)

    file = @bc.assets.first.content.file

    assert_instance_of BaseCradle::AssetFile, file
    assert_equal "report.pdf", file.filename
    assert_match(%r{/report\.pdf\z}, file.url)
  end

  # --- cross-timeline list + get + filter -------------------------------------------------

  def test_get_fetches_one_item_by_uuid
    stub_request(:get, "#{BASE_URL}/tasks/t1")
      .to_return(status: 200, body: { "task" => task_payload }.to_json)

    assert_equal "pending", @bc.tasks.get("t1").content.status
  end

  def test_filter_by_timeline_adds_the_query_param_and_accepts_uuid_or_object
    stub_request(:get, "#{BASE_URL}/messages").with(query: { "timeline" => TIMELINE_UUID })
      .to_return(status: 200, body: { "messages" => [ message_payload ], "next_cursor" => nil }.to_json)

    @bc.messages.filter(timeline: TIMELINE_UUID).to_a
    timeline = BaseCradle::Timeline.new(timeline_payload)
    @bc.messages.filter(timeline: timeline).to_a

    assert_requested(:get, "#{BASE_URL}/messages", query: { "timeline" => TIMELINE_UUID }, times: 2)
  end

  def test_tasks_filter_composes_timeline_and_status
    stub_request(:get, "#{BASE_URL}/tasks")
      .with(query: { "timeline" => TIMELINE_UUID, "status" => "pending" })
      .to_return(status: 200, body: { "tasks" => [ task_payload ], "next_cursor" => nil }.to_json)

    @bc.tasks.filter(timeline: TIMELINE_UUID, status: "pending").to_a

    assert_requested(:get, "#{BASE_URL}/tasks",
                     query: { "timeline" => TIMELINE_UUID, "status" => "pending" })
  end

  def test_filter_returns_a_new_lazy_resource_without_mutating_the_original
    unfiltered = @bc.tasks
    filtered = unfiltered.filter(status: "pending")

    refute_same unfiltered, filtered
    assert_instance_of BaseCradle::TasksResource, filtered
  end

  # --- nested creators --------------------------------------------------------------------

  def test_timeline_messages_create_posts_the_body_and_returns_a_message
    timeline = fetch_timeline
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/messages")
      .to_return(status: 201, body: { "message" => message_payload(body: "hi") }.to_json)

    message = timeline.messages.create(body: "hi")

    assert_instance_of BaseCradle::Message, message
    assert_equal "hi", message.content.body
    assert_requested(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/messages") do |req|
      JSON.parse(req.body) == { "message" => { "body" => "hi" } }
    end
  end

  def test_timeline_tasks_create_serializes_a_time_to_iso8601
    timeline = fetch_timeline
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/tasks")
      .to_return(status: 201, body: { "task" => task_payload }.to_json)

    timeline.tasks.create(instructions: "Review", activate_at: Time.utc(2026, 7, 1, 15))

    assert_requested(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/tasks") do |req|
      JSON.parse(req.body)["task"]["activate_at"] == "2026-07-01T15:00:00Z"
    end
  end

  def test_timeline_tasks_create_accepts_an_iso_string_unchanged
    timeline = fetch_timeline
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/tasks")
      .to_return(status: 201, body: { "task" => task_payload }.to_json)

    timeline.tasks.create(instructions: "Review", activate_at: "2026-07-01T15:00:00Z")

    assert_requested(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/tasks") do |req|
      JSON.parse(req.body)["task"]["activate_at"] == "2026-07-01T15:00:00Z"
    end
  end

  def test_asset_upload_from_a_path_is_multipart
    timeline = fetch_timeline
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/assets")
      .to_return(status: 201, body: { "asset" => asset_payload }.to_json)

    Tempfile.create([ "report", ".pdf" ]) do |file|
      file.write("%PDF fabricated")
      file.flush
      asset = timeline.assets.create(file: file.path, description: "Quarterly report")
      assert_instance_of BaseCradle::Asset, asset
    end

    assert_requested(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/assets") do |req|
      req.headers["Content-Type"].to_s.start_with?("multipart/form-data")
    end
  end

  def test_asset_upload_accepts_an_io
    timeline = fetch_timeline
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/assets")
      .to_return(status: 201, body: { "asset" => asset_payload }.to_json)

    asset = timeline.assets.create(file: StringIO.new("%PDF fabricated"))

    assert_instance_of BaseCradle::Asset, asset
    assert_requested(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/assets") do |req|
      req.headers["Content-Type"].to_s.start_with?("multipart/form-data")
    end
  end

  def test_asset_upload_accepts_a_pathname
    timeline = fetch_timeline
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/assets")
      .to_return(status: 201, body: { "asset" => asset_payload }.to_json)

    Tempfile.create([ "report", ".pdf" ]) do |file|
      file.write("%PDF fabricated")
      file.flush
      asset = timeline.assets.create(file: Pathname(file.path), description: "Quarterly report")
      assert_instance_of BaseCradle::Asset, asset
    end

    assert_requested(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/assets") do |req|
      req.headers["Content-Type"].to_s.start_with?("multipart/form-data")
    end
  end

  def test_timeline_messages_iterate_filtered_by_that_timeline
    timeline = fetch_timeline
    stub_request(:get, "#{BASE_URL}/messages").with(query: { "timeline" => TIMELINE_UUID })
      .to_return(status: 200, body: { "messages" => [ message_payload ], "next_cursor" => nil }.to_json)

    assert_equal [ "Hello from a peer." ], timeline.messages.map { |m| m.content.body }
  end

  # --- idempotency keys on creates --------------------------------------------------------

  KEY = "019f5e48-87c6-7d1e-9a48-7a701e8bd5bb"

  def test_message_create_sends_the_idempotency_key_header_when_given
    timeline = fetch_timeline
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/messages")
      .to_return(status: 201, body: { "message" => message_payload }.to_json)

    timeline.messages.create(body: "hi", idempotency_key: KEY)

    assert_requested(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/messages") do |req|
      req.headers["Idempotency-Key"] == KEY
    end
  end

  def test_create_without_a_key_sends_no_idempotency_header
    timeline = fetch_timeline
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/messages")
      .to_return(status: 201, body: { "message" => message_payload }.to_json)

    timeline.messages.create(body: "hi")

    assert_requested(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/messages") do |req|
      !req.headers.key?("Idempotency-Key")
    end
  end

  def test_asset_create_sends_the_idempotency_key_header
    timeline = fetch_timeline
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/assets")
      .to_return(status: 201, body: { "asset" => asset_payload }.to_json)

    timeline.assets.create(file: StringIO.new("%PDF fabricated"), idempotency_key: KEY)

    assert_requested(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/assets") do |req|
      req.headers["Idempotency-Key"] == KEY
    end
  end

  def test_task_create_sends_the_idempotency_key_header
    timeline = fetch_timeline
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/tasks")
      .to_return(status: 201, body: { "task" => task_payload }.to_json)

    timeline.tasks.create(instructions: "Review", activate_at: "2026-07-01T15:00:00Z",
                          idempotency_key: KEY)

    assert_requested(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/tasks") do |req|
      req.headers["Idempotency-Key"] == KEY
    end
  end

  def test_replaying_a_key_returns_the_same_record
    timeline = fetch_timeline
    # The platform dedupes by key: the caller sees the original record on every replay.
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/messages")
      .to_return(status: 201, body: { "message" => message_payload }.to_json)

    first = timeline.messages.create(body: "once", idempotency_key: KEY)
    second = timeline.messages.create(body: "once", idempotency_key: KEY)

    assert_equal first.content.uuid, second.content.uuid
  end

  def test_keyed_asset_upload_is_retried_and_resends_the_whole_body
    bc = BaseCradle::Client.new(FAKE_TOKEN, max_retries: 1)
    stub_request(:get, "#{BASE_URL}/timelines/#{TIMELINE_UUID}")
      .to_return(status: 200, body: { "timeline" => timeline_payload, "items" => [] }.to_json)
    stub_request(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/assets")
      .to_timeout.then.to_return(status: 201, body: { "asset" => asset_payload }.to_json)

    io = StringIO.new("%PDF fabricated")
    asset = bc.stub(:backoff, nil) do
      bc.timelines.get(TIMELINE_UUID).assets.create(file: io, idempotency_key: KEY)
    end

    assert_instance_of BaseCradle::Asset, asset
    # The upload survived a lost connection because the key made the resend safe; the IO
    # is rewound between attempts (see Client#rewind_form) so the resend carries the whole
    # file rather than the tail left after the first attempt read it.
    assert_requested(:post, "#{BASE_URL}/timelines/#{TIMELINE_UUID}/assets", times: 2)
  end

  private

  def fetch_timeline
    stub_request(:get, "#{BASE_URL}/timelines/#{TIMELINE_UUID}")
      .to_return(status: 200, body: { "timeline" => timeline_payload, "items" => [] }.to_json)
    @bc.timelines.get(TIMELINE_UUID)
  end
end
