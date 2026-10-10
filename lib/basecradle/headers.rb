# frozen_string_literal: true

require_relative "rendering"

module BaseCradle
  # A recorded HTTP request's headers: the wire's own spelling, looked up
  # case-insensitively. The platform records two kinds of inbound request verbatim — a
  # webhook delivery (+WebhookEventHeaders+) and a contact-page submission
  # (+ContactMessageHeaders+) — and both read through this one class's rules.
  #
  # A +Hash+ of exactly what the wire carried — one pair per header, +Content-Type+ and
  # +Content-Length+ included — so iterating, +keys+, +to_h+, +to_json+ and +==+ all read
  # the platform's own spelling and nothing is renamed. Only *lookup* folds case, because
  # header names are case-insensitive by RFC and the platform does not preserve the
  # sender's casing: it stores names canonicalized to Title-Case per segment
  # (+X-Github-Delivery+, not +X-GitHub-Delivery+). So a vendor's published spelling finds
  # the header it names, and so does any other casing of it:
  #
  #   event.content.headers["X-GitHub-Delivery"] # GitHub's own published spelling
  #   event.content.headers["x-github-delivery"] # the lowercase form
  #   event.content.headers["X-Github-Delivery"] # what the wire actually carried
  #
  # Every read that takes a header name folds: +fetch+, +dig+, +values_at+, +fetch_values+,
  # +to_proc+ and +key?+ (with +has_key?+, +include?+ and +member?+). A header that was
  # genuinely not sent is *absent*, never +nil+ — +[]+ and a fallback-less +fetch+ or
  # +fetch_values+ raise +KeyError+ naming the headers that did arrive, while +fetch+ with
  # a fallback, +dig+ and +values_at+ answer for it the way +Hash+ does.
  #
  # The methods that *reshape* the hash rather than read one name — +slice+, +except+,
  # +select+, +transform_values+ — and the mutators are left exactly as +Hash+ defines
  # them: case-sensitive, on the platform's own spelling. This is a read of one request
  # that already happened. Converting away from this type gives up the folding too
  # (+to_h+, <tt>{**headers}</tt>, and anything else that hands back a plain +Hash+);
  # +merge+ and +dup+ keep it.
  #
  # What it does *not* print is the values: +inspect+, +to_s+ and +pp+ render the header
  # names alone, because these are the sender's headers and one of them may be the
  # sender's credential. Every read is unaffected — and so is +to_json+, which still
  # emits the request verbatim. Converting away from this type gives the redaction up
  # exactly as it gives up the folding, and for the same reason: +slice+, +except+,
  # +select+, +transform_values+ and +to_h+ hand back a plain +Hash+, whose +inspect+
  # prints pairs.
  class RequestHeaders < Hash
    # Hash brings its own render, and a header value is another party's credential. The
    # module puts this class back under the SDK-wide rule; it sits between this class and
    # Hash in the ancestor chain, so all three doors resolve to it.
    include RendersNamesOnly

    # Hash's own exact-match membership, kept under a private name before the case-folding
    # +key?+ below takes the name: a caller who wrote the wire's own spelling is answered
    # without a scan, and it is the tiebreak if a derived copy holds two casings of one
    # name.
    alias_method :exact_key?, :key?
    private :exact_key?

    NO_FALLBACK = Object.new.freeze
    private_constant :NO_FALLBACK

    # +client:+ is unused — headers carry no verbs — but every wrapped model is built with
    # it (see ApiObject.attribute's +wrap:+), so it is accepted.
    def initialize(data, client: nil)
      super()
      update(data)
    end

    # The header's value, matched case-insensitively. Raises +KeyError+ when no casing of
    # the name was delivered.
    def [](name)
      wire = wire_name(name)
      wire.nil? ? raise_missing(name) : super(wire)
    end

    # Hash-like: the value, or the fallback — a default argument, or a block, which is
    # handed the name as written — when the header was not delivered. With no fallback it
    # behaves like +[]+.
    def fetch(name, fallback = NO_FALLBACK, &block)
      wire = wire_name(name)
      return super(wire) if wire
      return yield(name) if block
      return fallback unless fallback.equal?(NO_FALLBACK)

      raise_missing(name)
    end

    # Did this request carry the header, under any casing?
    def key?(name)
      !wire_name(name).nil?
    end
    alias_method :has_key?, :key?
    alias_method :include?, :key?
    alias_method :member?, :key?

    # Ruby's nil-returning read, case folded: the value, or +nil+ for a header that was
    # not delivered.
    def dig(name, *rest)
      wire = wire_name(name)
      wire.nil? ? nil : super(wire, *rest)
    end

    # Several headers at once, folded the same way — +nil+ for one that was not delivered,
    # as +Hash+ answers for a key it has no value for.
    def values_at(*names)
      names.map { |name| dig(name) }
    end

    # As +values_at+, but a header that was not delivered raises, exactly as +fetch+ does.
    def fetch_values(*names, &block)
      names.map { |name| block ? fetch(name, &block) : fetch(name) }
    end

    # +&headers+ — a header name to its value, folded, +nil+ for one not delivered.
    def to_proc
      ->(name) { dig(name) }
    end

    private

    # The header *names* this request carried, and none of their values.
    #
    # +Hash+'s own +inspect+ prints every pair, and these headers are the *sender's*,
    # stored verbatim by the platform: a sender that authenticates its POST to an ingest
    # URL puts its credential in one of them, and a contact-page visitor's browser may
    # carry its own cookies or tokens. So +logger.debug(event.content.headers)+ or
    # +logger.debug(message.headers)+ would write another party's secret into our logs.
    #
    # Only the human-facing render changes. Every *read* is untouched and still
    # wire-exact: lookups, +fetch+, +each+, +keys+, +to_h+, +to_json+, +==+.
    #
    # Names are sorted by their string form — a derived copy can hold a key that never
    # came off the wire, and a mixed-type +keys+ has no natural order otherwise.
    #
    # +nil+ for a request the platform recorded with no headers at all, so it renders as
    # the bare class. That is asked of the hash, not of the joined string: a request
    # carrying a single header whose *name* is the empty string joins to "" and must stay
    # distinguishable from one carrying nothing.
    def render_body
      return nil if empty?

      keys.sort_by(&:to_s).join(", ")
    end

    # The wire's own spelling of +name+, or nil if no casing of it was delivered. Anything
    # but a String is not a header name, so it is never matched rather than being coerced
    # into one: +headers[:host]+ finds nothing, and so misses like any other absent name.
    # Keys are type-checked too — +merge+ hands back one of these, so a caller's derived
    # copy can hold a key that never came off the wire.
    def wire_name(name)
      return nil unless name.is_a?(String)
      return name if exact_key?(name)

      each_key { |wire| return wire if wire.is_a?(String) && wire.casecmp?(name) }
      nil
    end

    def raise_missing(name)
      raise KeyError.new(
        "No #{name.inspect} header on this request. Header names are matched " \
        "case-insensitively, so no casing of it was sent either. " \
        "Headers present: #{keys.sort_by(&:to_s).inspect}",
        receiver: self, key: name
      )
    end
  end
end
