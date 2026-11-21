# frozen_string_literal: true

require_relative "serialization"

module BaseCradle
  # The shared cursor-pagination engine. Every list endpoint paginates the same way: up to
  # 50 per page, +next_cursor+ in the response passed back as +?before=+ for the next page,
  # a +null+ cursor meaning the end. Every list is newest first except the user directory,
  # which reads A to Z by handle. Every page also carries +total_count+: how many records
  # the whole list holds under the filters passed.
  #
  # The cursor is opaque: a record uuid in most lists, a handle in the directory. It is
  # passed back exactly as received, and nothing here checks its shape.
  #
  # Lazy and +Enumerable+: the first page is fetched when iteration starts, and page N+1
  # only when iteration crosses the page boundary — so +first+/+take+/+find+ stop early
  # and cursors never appear in calling code.
  class Paginator
    include Enumerable
    include NotSerializableCollection

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

    # How many records the whole list holds, every page counted, under this list's
    # filters. One GET of the first page, made on each call, so it reads the count as it
    # is now. It iterates nothing: unlike +Enumerable#count+, it never walks the pages.
    # A page without the field raises +MissingFieldError+ rather than guessing a number.
    def total_count
      page = @client.request("GET", @path, params: page_params(nil))
      page.fetch("total_count") do
        raise MissingFieldError, "The API did not return \"total_count\" for #{@path}. " \
                                 "Fields present: #{page.keys.sort.inspect}"
      end
    end

    private

    def page_params(cursor)
      cursor ? @params.merge("before" => cursor) : @params
    end
  end

  # What every list resource mixes in: iteration and +total_count+, both read from one
  # source. A resource defines a private +list+ returning either a Paginator or another
  # list resource (the nested +timeline.messages+ and the like return the cross-timeline
  # resource narrowed to their timeline), so a list never reads its pages two ways.
  module PaginatedList
    include NotSerializableCollection

    def each(&block)
      return enum_for(:each) unless block_given?

      list.each(&block)
    end

    # How many records this list holds, every page counted, under its filters — the
    # API's +total_count+. One GET of the first page on each call; nothing is iterated.
    #
    #   bc.messages.filter(timeline: timeline).total_count  # => 128
    def total_count
      list.total_count
    end
  end
end
