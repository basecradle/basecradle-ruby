# frozen_string_literal: true

require_relative "pagination"
require_relative "timeline"

module BaseCradle
  # Your timelines — the ones you own plus the ones you participate in.
  #
  # Iterable (auto-paginating, newest first): +bc.timelines.each+, or any Enumerable
  # method (+map+, +find+, +first+ — which stop early without fetching every page).
  class TimelinesResource
    include Enumerable

    def initialize(client)
      @client = client
    end

    def each(&block)
      return enum_for(:each) unless block_given?

      Paginator.new(@client, "/timelines", envelope_key: "timelines", model: Timeline).each(&block)
    end

    # Create a timeline owned by you (subject to your max_timelines cap).
    def create(name:)
      response = @client.request("POST", "/timelines", json: { "timeline" => { "name" => name } })
      subject_timeline(response)
    end

    # Fetch one timeline with its items inline (you must be a viewer).
    def get(uuid)
      subject_timeline(@client.request("GET", "/timelines/#{uuid}"))
    end

    private

    # The API returns a two-key envelope ({"timeline" => ..., "items" => ...}); merge it
    # into one Timeline so timeline.items reads through.
    def subject_timeline(response)
      Timeline.new(response.fetch("timeline").merge("items" => response["items"]), client: @client)
    end
  end
end
