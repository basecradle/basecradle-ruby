# frozen_string_literal: true

require "test_helper"
require "pp"
require "stringio"
require "yaml"

# A Client and a collection resource are not records, and serializing one used to emit
# something anyway. Under ActiveSupport a Client emitted its raw bc_uat_ token
# (Object#as_json is instance_values, walked recursively) and a collection emitted every
# record it could page (Enumerable#as_json calls to_a). Without ActiveSupport both
# emitted a heap address. Marshal and Psych walked the ivars whatever was loaded, and so
# emitted the token from both — a client AND a collection (#205). All of it now raises.
#
# This file pins the plain-Ruby half — no ActiveSupport in this process, deliberately, so
# the default environment most callers run in is what is under test.
# test/basecradle/active_support_test.rb covers the loaded-ActiveSupport half in a child
# process, because its core_ext cannot be unloaded once required.
class SerializationTest < Minitest::Test
  include TestSupport

  def setup
    @client = BaseCradle::Client.new(FAKE_TOKEN)
  end

  # `pp obj` writes to $stdout, so it is captured rather than asserted on indirectly.
  # PP.pp takes the sink explicitly, which keeps this out of the process's real stdout.
  def capture_pp(object)
    sink = StringIO.new
    PP.pp(object, sink)
    sink.string
  end

  # Every door out of an object and into bytes, written the way a caller writes it.
  # Keyed so a failure names the one that reopened. JSON.generate and YAML.dump reach
  # the same hooks as to_json and to_yaml; the nesting cases are tested separately.
  def serialization_doors
    {
      "to_json" => ->(object) { object.to_json },
      "as_json" => ->(object) { object.as_json },
      "Marshal.dump" => ->(object) { Marshal.dump(object) },
      "to_yaml" => ->(object) { object.to_yaml }
    }
  end

  # Every lazy collection the SDK hands out, instantiated the way a caller gets one.
  # Named so a failure says which resource regressed.
  def collections
    {
      "bc.timelines" => @client.timelines,
      "bc.messages" => @client.messages,
      "bc.assets" => @client.assets,
      "bc.tasks" => @client.tasks,
      "bc.webhook_endpoints" => @client.webhook_endpoints,
      "bc.webhook_events" => @client.webhook_events,
      "bc.sessions" => @client.sessions,
      "bc.users" => @client.users,
      "bc.messages.filter(...)" => @client.messages.filter(timeline: TIMELINE_UUID),
      "ItemsResource" => BaseCradle::ItemsResource.new(@client),
      "timeline.messages" => BaseCradle::TimelineMessages.new(@client, TIMELINE_UUID),
      "timeline.assets" => BaseCradle::TimelineAssets.new(@client, TIMELINE_UUID),
      "timeline.tasks" => BaseCradle::TimelineTasks.new(@client, TIMELINE_UUID),
      "timeline.webhook_endpoints" => BaseCradle::TimelineWebhookEndpoints.new(@client, TIMELINE_UUID),
      "timeline.webhook_events" => BaseCradle::TimelineWebhookEvents.new(@client, TIMELINE_UUID),
      "Paginator" => BaseCradle::Paginator.new(@client, "/timelines", envelope_key: "timelines",
                                                                     model: BaseCradle::Timeline)
    }
  end

  # Every class in the SDK that is Enumerable. WebhookEventHeaders subclasses Hash and
  # *is* a record (the delivery's headers), so it serializes as one; everything else is a
  # lazy, client-holding query that must refuse.
  def enumerable_classes
    sdk_classes.select { |klass| klass.include?(Enumerable) }
  end

  def lazy_collection_classes
    enumerable_classes.reject { |klass| klass <= Hash }
  end

  # --- the client -------------------------------------------------------------------------

  def test_serializing_a_client_raises_instead_of_emitting_the_token
    to_json = assert_raises(BaseCradle::NotSerializableError) { @client.to_json }
    as_json = assert_raises(BaseCradle::NotSerializableError) { @client.as_json }

    [ to_json, as_json ].each do |error|
      refute_includes error.message, FAKE_TOKEN
      assert_includes error.message, "bc_uat_"
      assert_includes error.message, "BaseCradle::Client"
    end
  end

  # The shapes a Rails app actually reaches the leak through: a bare `render json: bc`
  # (to_json), and a client nested in the document being rendered or logged.
  def test_a_client_nested_in_a_structure_raises_too
    assert_raises(BaseCradle::NotSerializableError) { JSON.generate(@client) }
    assert_raises(BaseCradle::NotSerializableError) { { conn: @client }.to_json }
    assert_raises(BaseCradle::NotSerializableError) { [ @client ].to_json }
    assert_raises(BaseCradle::NotSerializableError) { JSON.generate({ "conn" => @client }) }
  end

  # --- the collections --------------------------------------------------------------------

  def test_serializing_a_collection_raises_and_points_at_to_a
    collections.each do |name, collection|
      to_json = assert_raises(BaseCradle::NotSerializableError, name) { collection.to_json }
      as_json = assert_raises(BaseCradle::NotSerializableError, name) { collection.as_json }

      [ to_json, as_json ].each do |error|
        assert_includes error.message, ".to_a", name
        assert_includes error.message, collection.class.name, name
        refute_includes error.message, FAKE_TOKEN, name
      end
    end
  end

  def test_a_collection_nested_in_a_structure_raises_too
    collections.each do |name, collection|
      assert_raises(BaseCradle::NotSerializableError, name) { { items: collection }.to_json }
      assert_raises(BaseCradle::NotSerializableError, name) { JSON.generate([ collection ]) }
    end
  end

  # Refusing is half the point; the other half is that refusing happens *before* any
  # network. Serializing a lazy collection used to call to_a, which pages the whole
  # resource — an unbounded GET loop from inside a view render. No stub is registered
  # here, so a request would also trip WebMock; the registry assertion says it plainly.
  def test_serializing_never_issues_a_request
    subjects = collections.merge("bc" => @client)

    serialization_doors.each do |door, call|
      subjects.each do |name, subject|
        assert_raises(BaseCradle::NotSerializableError, "#{door} / #{name}") { call.call(subject) }
      end
    end

    assert_empty WebMock::RequestRegistry.instance.requested_signatures.hash,
                 "serializing must never reach the network"
  end

  # --- the other two doors: Marshal and YAML ------------------------------------------------

  # #204 shut the JSON door. Marshal and Psych walk instance variables directly, consult
  # no as_json, and need no ActiveSupport to do it — so they stayed open, and they are the
  # worse pair, because they put the credential *at rest*: ActiveSupport's cache stores
  # marshal what you write, a Marshal-backed session store does the same, and
  # Delayed::Job YAMLs its handler into the database. (Queue backends that serialize
  # arguments as JSON — ActiveJob and Sidekiq — go through to_json, closed in #198.)
  def test_marshalling_or_yamling_a_client_raises_instead_of_emitting_the_token
    marshal = assert_raises(BaseCradle::NotSerializableError) { Marshal.dump(@client) }
    yaml = assert_raises(BaseCradle::NotSerializableError) { @client.to_yaml }

    [ marshal, yaml ].each do |error|
      refute_includes error.message, FAKE_TOKEN
      assert_includes error.message, "bc_uat_"
      assert_includes error.message, "BaseCradle::Client"
    end

    # Marshal.load(Marshal.dump(x)) is the deep-copy idiom, and on a client it made a
    # second copy of the credential for as long as the process lived. It refuses at the
    # dump, so the load never runs and the copy is never made.
    assert_raises(BaseCradle::NotSerializableError) { Marshal.load(Marshal.dump(@client)) }
  end

  # The measured asymmetry this issue turned on: Enumerable#as_json shadowed the ivar walk,
  # so the JSON door never reached a collection's client — Marshal and Psych have no such
  # shadow and did. A collection is the commoner thing to hand to a cache, which made this
  # the wider hole of the two, not the narrower one.
  def test_marshalling_or_yamling_a_collection_raises_where_it_used_to_reach_the_token
    collections.each do |name, collection|
      marshal = assert_raises(BaseCradle::NotSerializableError, name) { Marshal.dump(collection) }
      yaml = assert_raises(BaseCradle::NotSerializableError, name) { collection.to_yaml }

      [ marshal, yaml ].each do |error|
        assert_includes error.message, collection.class.name, name
        refute_includes error.message, FAKE_TOKEN, name
        # .to_a alone is the JSON remedy and is NOT enough here — the array it returns
        # is full of models that each hold the client, so dumping it lands back on this
        # same error. A message that stopped at .to_a would be sending the reader in a
        # circle; test_the_remedy_each_message_gives_actually_works proves it does not.
        assert_includes error.message, ".to_a.map(&:to_h)", name
      end
    end
  end

  # Nesting is how it happens in practice — nobody caches a bare client, they cache a
  # struct that happens to hold one. Both walkers recurse, so both must refuse from depth.
  def test_a_client_or_collection_nested_in_a_structure_raises_through_both_doors
    [ @client, @client.messages ].each do |object|
      assert_raises(BaseCradle::NotSerializableError) { Marshal.dump({ conn: object }) }
      assert_raises(BaseCradle::NotSerializableError) { Marshal.dump([ object ]) }
      assert_raises(BaseCradle::NotSerializableError) { YAML.dump({ conn: object }) }
      assert_raises(BaseCradle::NotSerializableError) { [ object ].to_yaml }
    end
  end

  # A model holds the client that fetched it, so the walkers reach the token through one
  # — a live leak the JSON door never had, since a model serializes as its wire record.
  # Refusing is the right answer and the message names Client as what was reached; the
  # record itself is still perfectly cacheable, via the to_h that is what to cache.
  def test_a_model_holding_a_client_refuses_but_its_record_still_marshals
    message = BaseCradle::Message.new(message_payload, client: @client)

    [ -> { Marshal.dump(message) }, -> { message.to_yaml } ].each do |call|
      error = assert_raises(BaseCradle::NotSerializableError, &call)
      assert_includes error.message, "BaseCradle::Client"
      refute_includes error.message, FAKE_TOKEN
    end

    assert_equal message_payload, Marshal.load(Marshal.dump(message.to_h))
    refute_includes Marshal.dump(message.to_h), FAKE_TOKEN
  end

  # A refusal is only as good as the way out it names, and the way out differs by door:
  # a model serializes as its record through JSON, so "serialize the record you meant"
  # and ".to_a" are true there — and both walk back to the client under Marshal and
  # Psych. So the remedy each message gives is executed here rather than matched as a
  # string, which is the only way a message that sends the reader in a circle fails.
  def test_the_remedy_each_message_gives_actually_works
    model = BaseCradle::Message.new(message_payload, client: @client)
    page = [ model, BaseCradle::Message.new(message_payload, client: @client) ]

    client_refusal = assert_raises(BaseCradle::NotSerializableError) { Marshal.dump(model) }
    collection_refusal = assert_raises(BaseCradle::NotSerializableError) { Marshal.dump(@client.messages) }

    # Each message names its own way out — and names the client, because that is the
    # object actually reached by a caller who dumped a model and named no client at all.
    assert_includes client_refusal.message, "model.to_h"
    assert_includes client_refusal.message, "BaseCradle::Client"
    assert_includes collection_refusal.message, ".to_a.map(&:to_h)"

    # And the way out runs, through the door that raised, with no token in the bytes.
    [ Marshal.dump(model.to_h), model.to_h.to_yaml,
      Marshal.dump(page.map(&:to_h)), page.map(&:to_h).to_yaml ].each do |dumped|
      refute_includes dumped, FAKE_TOKEN
    end
    assert_equal message_payload, Marshal.load(Marshal.dump(model.to_h))
    assert_equal [ message_payload ] * 2, YAML.unsafe_load(page.map(&:to_h).to_yaml)
  end

  # One refusal per resource, reached through four doors — not four texts drifting apart.
  # Pinned by equality rather than by substring so a message edited for one door and not
  # the others fails here.
  def test_all_four_doors_refuse_with_the_identical_message
    ([ @client ] + collections.values).each do |object|
      messages = serialization_doors.transform_values do |call|
        assert_raises(BaseCradle::NotSerializableError, object.class.name) { call.call(object) }.message
      end

      assert_equal 1, messages.values.uniq.size,
                   "#{object.class} refuses differently per door: #{messages.inspect}"
    end
  end

  # --- the structural guard ---------------------------------------------------------------

  # A collection added later must not re-open the hole by forgetting the include. Every
  # Enumerable in the SDK is a lazy, client-holding query and must refuse — except
  # WebhookEventHeaders, which subclasses Hash and *is* a record (the delivery's headers),
  # so it serializes as one.
  def test_every_enumerable_resource_refuses_to_serialize
    refute_empty lazy_collection_classes
    lazy_collection_classes.each do |klass|
      assert klass.include?(BaseCradle::NotSerializableCollection),
             "#{klass} includes Enumerable but not NotSerializableCollection"
    end
  end

  # The one Enumerable that is exempt, named explicitly so adding a second exemption is
  # a deliberate edit here rather than a silent gap in the sweep above.
  def test_the_only_enumerable_that_still_serializes_is_the_headers_hash
    records = enumerable_classes.select { |klass| klass <= Hash }

    assert_equal [ BaseCradle::WebhookEventHeaders ], records
  end

  # And the exemption is pinned by behaviour, not only by that list: a delivery's headers
  # are a record, so caching one must keep working. The list check above would stay green
  # the day someone gives this class a @client ivar to hang a verb on — at which point
  # the Hash-subclass ivar walk reaches the client and the round-trips below raise
  # instead, which is the failure that matters (a Rails.cache.write of a delivery starts
  # raising in every app). as_json is absent because plain Ruby has no such method; the
  # ActiveSupport half covers it.
  def test_the_exempt_record_still_serializes_through_the_doors_plain_ruby_has
    headers = delivered_headers

    assert_equal headers.to_h, JSON.parse(headers.to_json)
    assert_equal headers.to_h, Marshal.load(Marshal.dump(headers)).to_h
    assert_equal headers.to_h, YAML.unsafe_load(headers.to_yaml).to_h
  end

  # ActiveSupport defines as_json/to_json on Enumerable itself, so a collection is only
  # safe while NotSerializable sits *ahead* of Enumerable in the ancestors. Checked over
  # every class reflectively, not over the hand-written list above — the class this would
  # catch is the one nobody remembered to add there.
  def test_the_refusal_outranks_enumerable_in_every_collections_ancestor_chain
    lazy_collection_classes.each do |klass|
      ancestors = klass.ancestors

      assert_operator ancestors.index(BaseCradle::NotSerializable), :<,
                      ancestors.index(Enumerable), klass.name
    end
  end

  # And the ordering cannot be got wrong in the first place: NotSerializableCollection
  # includes Enumerable itself, and Ruby does not move a module already in the chain, so
  # the refusal lands ahead of Enumerable whichever order the include lines are written
  # in. This is the case that used to be a rule in a comment.
  def test_the_ordering_holds_even_when_the_includes_are_written_backwards
    backwards = Class.new do
      include BaseCradle::NotSerializableCollection
      include Enumerable

      def each
        yield 1
      end
    end

    ancestors = backwards.ancestors

    # The ancestor order is the assertion, not the raise: ActiveSupport is deliberately
    # absent from this process, so plain Ruby would find the refusal either way. The
    # behavioural half of this lives in test/basecradle/active_support_test.rb.
    assert_operator ancestors.index(BaseCradle::NotSerializable), :<, ancestors.index(Enumerable)
    assert_raises(BaseCradle::NotSerializableError) { backwards.new.as_json }
  end

  # --- the other door: inspect and to_s ----------------------------------------------------

  # An inspect that dumps ivars prints the credential into every exception message, REPL
  # transcript and log line that touched a client — the same leak, different door.
  def test_client_inspect_and_to_s_redact_the_token
    assert_equal "#<BaseCradle::Client base_url=\"#{BASE_URL}\" token=[REDACTED]>", @client.inspect
    assert_equal @client.inspect, @client.to_s
    assert_equal "conn=#{@client.inspect}", "conn=#{@client}"
    refute_includes @client.inspect, FAKE_TOKEN
    refute_includes @client.to_s, FAKE_TOKEN
    # pp is the third door: it uses an object's own inspect when it defines one, which is
    # why every ApiObject and the Client are already safe there (#206 found the one class
    # that was not). Pinned rather than assumed.
    refute_includes capture_pp(@client), FAKE_TOKEN
  end

  # The resources hold the client, so Ruby's default inspect renders it — safe only
  # because Client#inspect is the redacting one above. Pinned so it stays that way.
  def test_collection_inspect_and_to_s_never_reach_the_token
    collections.each do |name, collection|
      refute_includes collection.inspect, FAKE_TOKEN, name
      refute_includes collection.to_s, FAKE_TOKEN, name
      # A collection has no inspect of its own, so pp dumps its ivars — reaching the
      # client, and safe only because Client#inspect above is the redacting one.
      refute_includes capture_pp(collection), FAKE_TOKEN, name
    end
  end

  # --- a third party's credential: WebhookEventHeaders -------------------------------------

  # The headers of an inbound delivery are the *sender's*, stored verbatim by the platform,
  # so one of them may be the sender's own credential — a POST authenticated to an ingest
  # URL carries its `Authorization` or `X-Api-Key` right there. WebhookEventHeaders is a
  # Hash descendant, so it inherited Hash's render, which prints every pair: that made
  # `logger.debug(event.content.headers)` write another party's secret into our logs. Every
  # other renderable object here is safe by one rule — ApiObject#inspect prints field names,
  # never values — and this was the one class outside it (#206).
  #
  # Values are fabricated, and are checked for in each of the four renders separately so a
  # failure names the door that reopened.
  SENDER_SECRETS = {
    "Authorization" => "Bearer nova-to-basecradle-2f8c41d7",
    "X-Api-Key" => "ak_live_9b4e7a12c5d38f60"
  }.freeze

  def delivered_headers
    payload = webhook_event_payload
    payload["content"]["headers"] = payload["content"]["headers"].merge(SENDER_SECRETS)
    BaseCradle::WebhookEvent.new(payload, client: @client).content.headers
  end

  def test_webhook_event_headers_render_the_header_names_and_never_a_value
    headers = delivered_headers

    assert_instance_of BaseCradle::WebhookEventHeaders, headers
    # Names, sorted, as ApiObject#inspect renders its fields.
    assert_equal "#<BaseCradle::WebhookEventHeaders #{headers.keys.sort.join(', ')}>",
                 headers.inspect
    # The names ARE the point — a render that dropped them would leak nothing and say
    # nothing, so the assertion above must not be satisfiable by an empty list.
    assert_includes headers.inspect, "Authorization"
    assert_includes headers.inspect, "X-Api-Key"

    renders = {
      "inspect" => headers.inspect,
      # Hash aliases to_s to its own inspect, one shared method entry, so overriding
      # inspect alone would leave both of these printing every value.
      "to_s" => headers.to_s,
      "interpolation" => "delivery=#{headers}",
      "%p" => format("%p", headers),
      # pp reaches for pretty_print, which Hash also brings — the one door inspect does
      # not cover on a Hash descendant.
      "pp" => capture_pp(headers),
      # And held by something else, which is how it reaches a log line in practice.
      "nested in a Hash" => { delivery: headers }.inspect
    }

    SENDER_SECRETS.each_value do |secret|
      renders.each { |door, rendered| refute_includes rendered, secret, door }
    end
  end

  # Only the render changed: every read still hands back exactly what the wire carried,
  # including the folded lookup that is this class's whole reason to exist.
  def test_webhook_event_headers_still_read_exactly_what_the_wire_carried
    headers = delivered_headers

    SENDER_SECRETS.each do |name, secret|
      assert_equal secret, headers[name]
      assert_equal secret, headers[name.downcase] # folded, as HTTP means it
      assert_equal secret, headers.fetch(name)
      assert_equal secret, headers.to_h[name]
      assert_equal secret, JSON.parse(headers.to_json)[name]
    end
  end

  # A derived copy is still one of these (merge keeps the type), so the render travels
  # with it — through all three doors, since a copy is built by dup rather than through
  # initialize, and a copy with a correlation header added is what a caller actually logs.
  def test_a_derived_copy_of_the_headers_renders_the_same_way
    derived = delivered_headers.merge("X-Late-Header" => "added")

    assert_instance_of BaseCradle::WebhookEventHeaders, derived
    assert_includes derived.inspect, "X-Late-Header"
    [ derived.inspect, derived.to_s, "delivery=#{derived}", capture_pp(derived) ].each do |rendered|
      SENDER_SECRETS.each_value { |secret| refute_includes rendered, secret }
    end
  end

  # The names are sorted with `sort_by(&:to_s)`, not `sort`, and that is load-bearing:
  # `merge` accepts any key (wire_name's own comment says so, and webhooks_test exercises
  # it), and a plain sort raises `ArgumentError: comparison of String with :host failed`.
  # Aligning this with ApiObject#inspect's `keys.sort` would pass every other test here
  # and then raise from a log statement.
  def test_the_render_survives_a_key_that_never_came_off_the_wire
    derived = delivered_headers.merge(host: "elsewhere")

    assert_includes derived.inspect, "host"
    SENDER_SECRETS.each_value { |secret| refute_includes derived.inspect, secret }
  end

  # The other arm of the render. A delivery the platform records with no headers at all
  # renders as the bare class, with no dangling separator — and it is distinct from a
  # delivery carrying a header whose name is the empty string, which `size` reports as 1.
  def test_a_delivery_with_no_headers_renders_as_the_bare_class
    assert_equal "#<BaseCradle::WebhookEventHeaders>",
                 BaseCradle::WebhookEventHeaders.new({}).inspect
    refute_equal "#<BaseCradle::WebhookEventHeaders>",
                 BaseCradle::WebhookEventHeaders.new({ "" => "x" }).inspect
  end

  # --- the error itself ---------------------------------------------------------------------

  # Rescuing BaseCradle::Error catches everything this SDK raises, this included — and
  # it carries no problem document, because it never reached the API.
  def test_the_refusal_is_a_basecradle_error_with_no_problem_document
    error = assert_raises(BaseCradle::Error) { @client.to_json }

    assert_instance_of BaseCradle::NotSerializableError, error
    assert_nil error.status
    assert_nil error.code
    assert_nil error.problem
  end

  # The fix must not touch the models: #191 made those serialize as the record they
  # stand for, and they still do — including one attached to a client.
  def test_models_still_serialize_as_their_record
    message = BaseCradle::Message.new(message_payload, client: @client)

    assert_equal message_payload, JSON.parse(message.to_json)
    assert_equal message_payload, message.as_json
    refute_includes message.to_json, FAKE_TOKEN
  end
end
