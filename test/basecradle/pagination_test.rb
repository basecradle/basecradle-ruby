# frozen_string_literal: true

require "test_helper"

# Every list page carries total_count beside next_cursor: how many records the whole list
# holds under the filters passed, every page counted (api.md, "Pagination"). The SDK reads
# it from the first page, without iterating, on every list it offers.
class PaginationTest < Minitest::Test
  include TestSupport

  # The cursor page 1 hands back: a record uuid, opaque to the caller.
  PAGE_TWO_CURSOR = "019e7750-66ee-7c4f-bcdc-7c5d2eddc662"

  def setup
    @bc = BaseCradle::Client.new(FAKE_TOKEN)
  end

  def page(key, rows, next_cursor: nil, total_count: rows.size)
    { status: 200, body: { key => rows, "next_cursor" => next_cursor, "total_count" => total_count }.to_json }
  end

  # --- one page, nothing iterated --------------------------------------------------------

  def test_total_count_reads_the_first_page_and_iterates_nothing
    stub_request(:get, "#{BASE_URL}/timelines")
      .to_return(page("timelines", [ timeline_payload ], next_cursor: PAGE_TWO_CURSOR, total_count: 128))

    assert_equal 128, @bc.timelines.total_count
    assert_requested(:get, "#{BASE_URL}/timelines", times: 1)
    assert_not_requested(:get, "#{BASE_URL}/timelines", query: hash_including("before"))
  end

  def test_total_count_is_read_fresh_on_each_call
    stub_request(:get, "#{BASE_URL}/timelines")
      .to_return(page("timelines", [ timeline_payload ], total_count: 1))
      .then.to_return(page("timelines", [ timeline_payload, timeline_payload ], total_count: 2))

    timelines = @bc.timelines

    assert_equal 1, timelines.total_count
    assert_equal 2, timelines.total_count
  end

  # The SDK never invents a number the API withheld.
  def test_a_page_without_total_count_raises_missing_field
    stub_request(:get, "#{BASE_URL}/timelines")
      .to_return(status: 200, body: { "timelines" => [], "next_cursor" => nil }.to_json)

    error = assert_raises(BaseCradle::MissingFieldError) { @bc.timelines.total_count }
    assert_includes error.message, "total_count"
  end

  # --- across pages ----------------------------------------------------------------------

  # The total does not shrink as you page: page two reports the same number as page one,
  # and it is the number of records iteration delivers.
  def test_total_count_is_the_whole_list_across_pages
    stub_request(:get, "#{BASE_URL}/timelines")
      .to_return(page("timelines", [ timeline_payload(name: "newest") ],
                      next_cursor: PAGE_TWO_CURSOR, total_count: 2))
    stub_request(:get, "#{BASE_URL}/timelines").with(query: { "before" => PAGE_TWO_CURSOR })
      .to_return(page("timelines", [ timeline_payload(name: "older") ], total_count: 2))

    timelines = @bc.timelines

    assert_equal %w[newest older], timelines.map(&:name)
    assert_equal timelines.count, timelines.total_count
  end

  # --- under the filters -----------------------------------------------------------------

  def test_total_count_counts_under_the_filters_passed
    stub_request(:get, "#{BASE_URL}/tasks")
      .with(query: { "timeline" => TIMELINE_UUID, "status" => "pending" })
      .to_return(page("tasks", [ task_payload ], total_count: 3))

    assert_equal 3, @bc.tasks.filter(timeline: TIMELINE_UUID, status: "pending").total_count
  end

  def test_a_timelines_nested_list_counts_only_that_timeline
    stub_request(:get, "#{BASE_URL}/messages").with(query: { "timeline" => TIMELINE_UUID })
      .to_return(page("messages", [ message_payload ], total_count: 42))
    timeline = BaseCradle::Timeline.new(timeline_payload, client: @bc)

    assert_equal 42, timeline.messages.total_count
  end

  # --- every list ------------------------------------------------------------------------

  # Every list the API pages — the user directory included — reports its total.
  def test_every_list_reports_its_total
    lists = {
      "/timelines" => [ "timelines", @bc.timelines ],
      "/messages" => [ "messages", @bc.messages ],
      "/assets" => [ "assets", @bc.assets ],
      "/tasks" => [ "tasks", @bc.tasks ],
      "/webhook_endpoints" => [ "webhook_endpoints", @bc.webhook_endpoints ],
      "/webhook_events" => [ "webhook_events", @bc.webhook_events ],
      "/users" => [ "users", @bc.users ],
      "/users/sessions" => [ "sessions", @bc.sessions ],
      "/contact_messages" => [ "contact_messages", @bc.contact_messages ],
      "/notes" => [ "notes", @bc.notes ]
    }
    lists.each_with_index do |(path, (key, _)), index|
      stub_request(:get, "#{BASE_URL}#{path}").to_return(page(key, [], total_count: 100 + index))
    end

    lists.each_with_index do |(path, (_, list)), index|
      assert_equal 100 + index, list.total_count, "#{path} did not report its total"
    end
  end

  # And so does every list nested on a timeline, narrowed to that timeline.
  def test_every_nested_list_reports_its_timelines_total
    timeline = BaseCradle::Timeline.new(timeline_payload, client: @bc)
    nested = {
      "messages" => timeline.messages,
      "assets" => timeline.assets,
      "tasks" => timeline.tasks,
      "webhook_endpoints" => timeline.webhook_endpoints,
      "webhook_events" => timeline.webhook_events
    }
    nested.each_key.with_index do |key, index|
      stub_request(:get, "#{BASE_URL}/#{key}").with(query: { "timeline" => TIMELINE_UUID })
        .to_return(page(key, [], total_count: 200 + index))
    end

    nested.each_with_index do |(key, list), index|
      assert_equal 200 + index, list.total_count, "timeline.#{key} did not report its total"
    end
  end

  # A list resource added later must not skip the total: every lazy collection reads its
  # pages through PaginatedList, which is what gives it total_count. The Paginator is the
  # engine behind them, not a resource a caller is handed.
  def test_every_list_resource_offers_total_count
    lists = sdk_classes.select { |klass| klass.include?(BaseCradle::NotSerializableCollection) }
    resources = lists - [ BaseCradle::Paginator ]

    refute_empty resources
    resources.each do |klass|
      assert klass.include?(BaseCradle::PaginatedList), "#{klass} is a list without PaginatedList"
    end
  end
end
