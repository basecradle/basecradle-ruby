# frozen_string_literal: true

module BaseCradle
  # The shared cursor-pagination engine. Every list endpoint paginates the same way:
  # newest first, up to 50 per page, +next_cursor+ in the response passed back as
  # +?before=+ for the next (older) page, a +null+ cursor meaning the end.
  #
  # Lazy and +Enumerable+: the first page is fetched when iteration starts, and page N+1
  # only when iteration crosses the page boundary — so +first+/+take+/+find+ stop early
  # and cursors never appear in calling code.
  class Paginator
    include Enumerable

    def initialize(client, path, envelope_key:, model:, params: nil)
      @client = client
      @path = path
      @envelope_key = envelope_key
      @model = model
      @params = params || {}
    end

    def each
      return enum_for(:each) unless block_given?

      cursor = nil
      loop do
        page = @client.request("GET", @path, params: page_params(cursor))
        page.fetch(@envelope_key).each { |data| yield @model.new(data, client: @client) }
        cursor = page["next_cursor"]
        break if cursor.nil?
      end
    end

    private

    def page_params(cursor)
      cursor ? @params.merge("before" => cursor) : @params
    end
  end
end
