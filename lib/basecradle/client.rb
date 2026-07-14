# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "dashboard"
require_relative "errors"
require_relative "items"
require_relative "sessions"
require_relative "timelines"
require_relative "user"
require_relative "version"
require_relative "webhooks"

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

    # Automatic retries are off by default — a create that succeeded server-side but lost
    # its response would be resent, so retrying is only ever safe once you opt in with an
    # idempotency key (see +max_retries+).
    DEFAULT_MAX_RETRIES = 0

    # Backoff between retries doubles each attempt from this base (0.5s, 1s, 2s, …).
    RETRY_BASE_DELAY = 0.5

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

    attr_reader :token, :base_url, :max_retries

    # The Dashboard .md URL the API points new peers at; set by +login+.
    attr_reader :start_here

    # +max_retries+ opts into automatic retries on a lost connection (a timeout or dropped
    # connection, where the request may never have reached the API). It is 0 by default —
    # off. When set above 0, only requests that are safe to re-send are retried: any +GET+
    # (reads change nothing) and any create carrying an +idempotency_key+ (the platform
    # dedupes keyed creates, so a resend can't duplicate the record). An unkeyed +POST+ is
    # never retried, whatever this is set to. Retries back off exponentially.
    def initialize(token = nil, base_url: DEFAULT_BASE_URL, timeout: DEFAULT_TIMEOUT,
                   max_retries: DEFAULT_MAX_RETRIES)
      resolved = token || ENV.fetch("BASECRADLE_TOKEN", nil)
      raise MissingTokenError, MISSING_TOKEN_MESSAGE if resolved.nil? || resolved.empty?
      raise ArgumentError, "max_retries must be >= 0" if max_retries.negative?

      @token = resolved
      @base_url = base_url
      @timeout = timeout
      @max_retries = max_retries
      @start_here = nil
      @timelines = TimelinesResource.new(self)
      @messages = MessagesResource.new(self)
      @assets = AssetsResource.new(self)
      @tasks = TasksResource.new(self)
      @webhook_endpoints = WebhookEndpointsResource.new(self)
      @webhook_events = WebhookEventsResource.new(self)
      @sessions = SessionsResource.new(self)
      @users = UsersResource.new(self)
    end

    # Your timelines — iterable (auto-paginating, newest first), with create/get.
    attr_reader :timelines

    # Cross-timeline lists, newest first — iterable, filterable (.filter), with get.
    attr_reader :messages, :assets, :tasks, :webhook_endpoints, :webhook_events

    # Your own credentials — list and revoke them yourself (see SessionsResource).
    attr_reader :sessions

    # The directory of other peers, and the trust handshake.
    attr_reader :users

    # Mint a fresh token via POST /session and return an authenticated client.
    #
    # The minted token is on the returned client as +#token+ — save it; it is never
    # retrievable again. +name+ is an optional label to tell credentials apart later.
    def self.login(email_address:, password:, name: nil, base_url: DEFAULT_BASE_URL,
                   timeout: DEFAULT_TIMEOUT, max_retries: DEFAULT_MAX_RETRIES)
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
      client = new(body["token"], base_url: base_url, timeout: timeout, max_retries: max_retries)
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
    #
    # +json+ sends an application/json body; +form+ (an array of Net::HTTP +set_form+
    # parts) sends a multipart/form-data body (used for asset uploads). +params+ are
    # query-string parameters. +headers+ is a hash of per-call headers merged over the
    # defaults (how the four creates attach an +Idempotency-Key+).
    def request(method, path, json: nil, params: nil, form: nil, headers: nil)
      uri = build_uri(path, params)
      http_request = build_request(method, uri, json, form, headers)
      response = send_with_retry(method, uri, http_request, form)
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

    # Send the request, retrying on a lost connection up to +@max_retries+ times when the
    # request is safe to re-send. Everything else — the send itself, error mapping — is
    # unchanged from a single call.
    def send_with_retry(method, uri, http_request, form)
      attempt = 0
      begin
        self.class.perform(uri, http_request, @timeout)
      rescue APIConnectionError
        attempt += 1
        raise if attempt > @max_retries || !retryable?(method, http_request)

        rewind_form(form)
        backoff(attempt)
        retry
      end
    end

    # A multipart upload may have partly consumed its file IO before the connection failed;
    # rewind any rewindable part so the resend transmits the whole body from the start.
    def rewind_form(form)
      form&.each { |part| part[1].rewind if part[1].respond_to?(:rewind) }
    end

    # A request is safe to auto-retry only when re-sending it can't create a duplicate: a
    # +GET+ (reads change nothing), or any request carrying an +Idempotency-Key+ (the
    # platform dedupes keyed creates). An unkeyed write is never retried.
    def retryable?(method, http_request)
      return true if method.to_s.upcase == "GET"

      key = http_request["Idempotency-Key"]
      !(key.nil? || key.empty?)
    end

    # Exponential backoff before the next attempt (attempt is 1-based).
    def backoff(attempt)
      sleep(RETRY_BASE_DELAY * (2**(attempt - 1)))
    end

    def build_uri(path, params)
      uri = URI.parse("#{@base_url.chomp('/')}#{path}")
      uri.query = URI.encode_www_form(params) if params && !params.empty?
      uri
    end

    def build_request(method, uri, json, form = nil, headers = nil)
      klass = {
        "GET" => Net::HTTP::Get, "POST" => Net::HTTP::Post,
        "PUT" => Net::HTTP::Put, "PATCH" => Net::HTTP::Patch, "DELETE" => Net::HTTP::Delete
      }.fetch(method.to_s.upcase)

      request = klass.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Accept"] = "application/json"
      request["User-Agent"] = "basecradle-ruby/#{VERSION}"
      headers&.each { |name, value| request[name.to_s] = value unless value.nil? }
      if form
        request.set_form(form, "multipart/form-data")
      elsif json
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
