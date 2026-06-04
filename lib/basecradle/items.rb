# frozen_string_literal: true

require "time"

require_relative "api_object"
require_relative "pagination"
require_relative "user"

module BaseCradle
  # --- models ---------------------------------------------------------------------------

  # The envelope shape every timeline item shares. +timeline+ is in reference form (just
  # a uuid) — dereference it with bc.timelines.get(item.timeline.uuid) when you need it.
  class Item < ApiObject
    attribute :type
    attribute :created_at
    attribute :user, wrap: User
    attribute :timeline, wrap: Reference
  end

  # A message's content: its uuid and body.
  class MessageContent < ApiObject
    attribute :uuid
    attribute :body
  end

  # A text post on a timeline.
  class Message < Item
    attribute :content, wrap: MessageContent
  end

  # An asset's attached file: metadata plus a dereferenceable download URL.
  class AssetFile < ApiObject
    attribute :filename
    attribute :byte_size
    attribute :content_type
    attribute :checksum # base64 MD5 of the blob
    attribute :url
  end

  # An asset's content: description and the attached file.
  class AssetContent < ApiObject
    attribute :uuid
    attribute :description
    attribute :file, wrap: AssetFile
  end

  # A file (with optional description) posted to a timeline.
  class Asset < Item
    attribute :content, wrap: AssetContent
  end

  # A task's content: instructions, schedule, and status.
  class TaskContent < ApiObject
    attribute :uuid
    attribute :instructions
    attribute :activate_at
    attribute :status # "pending" | "activated" | "blocked_timeline_locked"
  end

  # An instruction with a scheduled activation time.
  class Task < Item
    attribute :content, wrap: TaskContent
  end

  # --- cross-timeline list + get + filter -----------------------------------------------

  # The shared cross-timeline pattern: iterate everything you can see (newest first,
  # auto-paginating), narrow with .filter, or fetch one by uuid. Subclasses set PATH /
  # PLURAL / SINGULAR / MODEL.
  class ItemsResource
    include Enumerable

    def initialize(client, filters: {})
      @client = client
      @filters = filters
    end

    def each(&block)
      return enum_for(:each) unless block_given?

      Paginator.new(@client, self.class::PATH, envelope_key: self.class::PLURAL,
                                               model: self.class::MODEL, params: @filters).each(&block)
    end

    # A new lazy resource narrowed to one timeline (a Timeline or a uuid). Filters compose.
    def filter(timeline: nil)
      self.class.new(@client, filters: merge_filters(timeline: timeline))
    end

    # Fetch one item by its own uuid (you must be a viewer of its timeline).
    def get(uuid)
      response = @client.request("GET", "#{self.class::PATH}/#{uuid}")
      self.class::MODEL.new(response.fetch(self.class::SINGULAR), client: @client)
    end

    private

    def merge_filters(**values)
      merged = @filters.dup
      values.each { |key, value| merged[key.to_s] = BaseCradle.uuid_of(value) unless value.nil? }
      merged
    end
  end

  # Messages from every timeline you can view, newest first.
  class MessagesResource < ItemsResource
    PATH = "/messages"
    PLURAL = "messages"
    SINGULAR = "message"
    MODEL = Message
  end

  # Assets from every timeline you can view, newest first.
  class AssetsResource < ItemsResource
    PATH = "/assets"
    PLURAL = "assets"
    SINGULAR = "asset"
    MODEL = Asset
  end

  # Tasks from every timeline you can view, newest first.
  class TasksResource < ItemsResource
    PATH = "/tasks"
    PLURAL = "tasks"
    SINGULAR = "task"
    MODEL = Task

    # Narrow by timeline and/or status ("pending" | "activated" | "blocked_timeline_locked").
    def filter(timeline: nil, status: nil)
      filters = merge_filters(timeline: timeline)
      filters["status"] = status unless status.nil?
      self.class.new(@client, filters: filters)
    end
  end

  # --- nested creators on a Timeline (timeline.messages / .assets / .tasks) --------------

  # One timeline's messages: create here, or iterate (newest first).
  class TimelineMessages
    include Enumerable

    def initialize(client, timeline_uuid)
      @client = client
      @timeline_uuid = timeline_uuid
    end

    # Post a message to this timeline (you must be a viewer; the timeline must be unlocked).
    def create(body:)
      response = @client.request("POST", "/timelines/#{@timeline_uuid}/messages",
                                 json: { "message" => { "body" => body } })
      Message.new(response.fetch("message"), client: @client)
    end

    def each(&block)
      MessagesResource.new(@client).filter(timeline: @timeline_uuid).each(&block)
    end
  end

  # One timeline's assets: upload here (multipart), or iterate (newest first).
  class TimelineAssets
    include Enumerable

    def initialize(client, timeline_uuid)
      @client = client
      @timeline_uuid = timeline_uuid
    end

    # Upload a file to this timeline. +file+ is a path or a binary IO; +description+ optional.
    def create(file:, description: nil)
      filename, io, opened = open_upload(file)
      parts = [ [ "asset[file]", io, { filename: filename } ] ]
      parts << [ "asset[description]", description ] unless description.nil?
      begin
        response = @client.request("POST", "/timelines/#{@timeline_uuid}/assets", form: parts)
      ensure
        io.close if opened
      end
      Asset.new(response.fetch("asset"), client: @client)
    end

    def each(&block)
      AssetsResource.new(@client).filter(timeline: @timeline_uuid).each(&block)
    end

    private

    def open_upload(file)
      if file.is_a?(String) || file.is_a?(Pathname)
        path = file.to_s
        [ File.basename(path), File.open(path, "rb"), true ]
      else
        name = file.respond_to?(:path) ? File.basename(file.path) : "file"
        [ name, file, false ]
      end
    end
  end

  # One timeline's tasks: create here, or iterate (newest first).
  class TimelineTasks
    include Enumerable

    def initialize(client, timeline_uuid)
      @client = client
      @timeline_uuid = timeline_uuid
    end

    # Schedule a task on this timeline. +activate_at+ accepts a Time/DateTime (serialized
    # to ISO 8601 — make it timezone-aware to be unambiguous) or an ISO 8601 string.
    def create(instructions:, activate_at:)
      activate_at = activate_at.iso8601 if activate_at.respond_to?(:iso8601)
      response = @client.request(
        "POST", "/timelines/#{@timeline_uuid}/tasks",
        json: { "task" => { "instructions" => instructions, "activate_at" => activate_at } }
      )
      Task.new(response.fetch("task"), client: @client)
    end

    def each(&block)
      TasksResource.new(@client).filter(timeline: @timeline_uuid).each(&block)
    end
  end
end
