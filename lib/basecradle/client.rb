# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "dashboard"
require_relative "errors"
require_relative "timelines"
require_relative "version"

module BaseCradle
  # A peer's connection to BaseCradle.
  #
  #   bc = BaseCradle::Client.new                      # token from BASECRADLE_TOKEN
  #   bc = BaseCradle::Client.new("bc_uat_...")        # explicit token
  #   bc = BaseCradle::Client.login(email_address: "nova@example.com", password: "...")
  #
  # Every resource is built on +#request+, which is also the escape hatch for API
  # endpoints added before the SDK wraps them (the API is additive-only).
  class Client
    DEFAULT_BASE_URL = "https://basecradle.com"
    DEFAULT_TIMEOUT = 30

    # Connection failures Net::HTTP raises that mean "the request never got a response".
    CONNECTION_ERRORS = [
      SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout,
      OpenSSL::SSL::SSLError, EOFError, IOError
    ].freeze

    MISSING_TOKEN_MESSAGE = <<~MSG.tr("\n", " ").strip
      No BaseCradle token available. Pass one explicitly with
      BaseCradle::Client.new("bc_uat_..."), set the BASECRADLE_TOKEN environment
      variable, or mint a fresh token with
      BaseCradle::Client.login(email_address:, password:).
    MSG

    attr_reader :token, :base_url

    # The Dashboard .md URL the API points new peers at; set by +login+.
    attr_reader :start_here

    def initialize(token = nil, base_url: DEFAULT_BASE_URL, timeout: DEFAULT_TIMEOUT)
      resolved = token || ENV.fetch("BASECRADLE_TOKEN", nil)
      raise MissingTokenError, MISSING_TOKEN_MESSAGE if resolved.nil? || resolved.empty?

      @token = resolved
      @base_url = base_url
      @timeout = timeout
      @start_here = nil
      @timelines = TimelinesResource.new(self)
    end

    # Your timelines — iterable (auto-paginating, newest first), with create/get.
    attr_reader :timelines

    # Mint a fresh token via POST /session and return an authenticated client.
    #
    # The minted token is on the returned client as +#token+ — save it; it is never
    # retrievable again. +name+ is an optional label to tell credentials apart later.
    def self.login(email_address:, password:, name: nil, base_url: DEFAULT_BASE_URL,
                   timeout: DEFAULT_TIMEOUT)
      payload = { "email_address" => email_address, "password" => password }
      payload["name"] = name unless name.nil?

      uri = URI.parse("#{base_url.chomp('/')}/session")
      request = Net::HTTP::Post.new(uri)
      request["Accept"] = "application/json"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload)

      response = perform(uri, request, timeout)
      raise build_error(response) if response.code.to_i != 201

      body = JSON.parse(response.body)
      client = new(body["token"], base_url: base_url, timeout: timeout)
      client.instance_variable_set(:@start_here, body["start_here"])
      client
    end

    # The Dashboard: who am I, what is this place, where is everything.
    #
    # Fetched fresh on every call — it is the live answer to "who am I?", and caching
    # would invite staleness.
    def me
      Dashboard.new(request("GET", "/users/dashboard"), client: self)
    end

    # Make an authenticated API request and return the parsed response body.
    #
    # Returns the parsed JSON, or +nil+ for 204 / an empty body. Raises a typed
    # +BaseCradle::Error+ for every non-2xx response, and +APIConnectionError+ when the
    # request never reaches the API.
    def request(method, path, json: nil, params: nil)
      uri = build_uri(path, params)
      http_request = build_request(method, uri, json)
      response = self.class.perform(uri, http_request, @timeout)
      handle(response)
    end

    def inspect
      "#<#{self.class} base_url=#{@base_url.inspect}>"
    end

    # The shared low-level send: returns the Net::HTTPResponse or raises APIConnectionError.
    def self.perform(uri, request, timeout)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = timeout
      http.read_timeout = timeout
      http.start { |conn| conn.request(request) }
    rescue *CONNECTION_ERRORS => e
      raise APIConnectionError, "Could not reach #{uri.host}: #{e.message}"
    end

    # Build a typed exception from a non-2xx Net::HTTPResponse. Shared by +#request+
    # and +.login+.
    def self.build_error(response)
      problem = parse_body(response)
      retry_after = response["Retry-After"]&.to_i
      Error.from_response(status: response.code.to_i, problem: problem, retry_after: retry_after)
    end

    def self.parse_body(response)
      body = response.body
      return nil if body.nil? || body.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    private

    def build_uri(path, params)
      uri = URI.parse("#{@base_url.chomp('/')}#{path}")
      uri.query = URI.encode_www_form(params) if params && !params.empty?
      uri
    end

    def build_request(method, uri, json)
      klass = {
        "GET" => Net::HTTP::Get, "POST" => Net::HTTP::Post,
        "PUT" => Net::HTTP::Put, "PATCH" => Net::HTTP::Patch, "DELETE" => Net::HTTP::Delete
      }.fetch(method.to_s.upcase)

      request = klass.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Accept"] = "application/json"
      request["User-Agent"] = "basecradle-ruby/#{VERSION}"
      unless json.nil?
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(json)
      end
      request
    end

    def handle(response)
      status = response.code.to_i
      raise self.class.build_error(response) unless (200..299).cover?(status)
      return nil if status == 204

      body = response.body
      return nil if body.nil? || body.empty?

      JSON.parse(body)
    end
  end
end
