# frozen_string_literal: true

require "test_helper"
require "pp"

# One rule holds every render in this SDK: an object prints its field *names*, never its
# field values. It is what keeps the `bc_uat_` token out of a log line, an inbound sender's
# credential out of `logger.debug(event.content.headers)`, and an endpoint's ingest_url out
# of a REPL transcript.
#
# Before #212 the rule was three hand-rolled copies of the same three methods — ApiObject,
# Client, WebhookEventHeaders — and nothing asked the question of a fourth class. That is
# not a hypothetical: it is how 0.10.2's leak arrived. WebhookEventHeaders was added as a
# Hash descendant in #183, Hash brought its own render, every header value printed, and the
# whole suite stayed green because no test was looking.
#
# So the rule is one module now, and this file is the thing that looks. The reflective guard
# below is the point of the file: it walks the SDK's own constants rather than a list
# somebody has to remember to extend, which is the same stance
# `test_the_only_enumerable_that_still_serializes_is_the_headers_hash` takes for the sibling
# serialization rule — and the reason a collection added later cannot skip that one.
class RenderingTest < Minitest::Test
  FAKE_TOKEN = "bc_uat_KqI8zFxkQ0OZ8vYwT7mWcVtR3nSdLpEa"
  BASE_URL = "https://basecradle.com"

  # The three doors a render arrives through. `inspect` is `p` and a REPL echo; `to_s` is
  # string interpolation and `puts`; `pretty_print` is `pp`.
  RENDER_METHODS = %i[inspect to_s pretty_print].freeze

  def setup
    @client = BaseCradle::Client.new(FAKE_TOKEN, base_url: BASE_URL)
  end

  # --- the reflective guard ----------------------------------------------------------------

  # Every class the SDK defines that renders as itself must get all three doors from the one
  # module. Pinned to the module rather than merely to "some method defined inside
  # BaseCradle" because a fourth hand-rolled copy is exactly what went wrong: two of the
  # three old copies carried a near-verbatim duplicate of the same comment, and the class
  # that had no copy at all printed its values for two releases.
  def test_every_renderable_class_gets_all_three_doors_from_the_one_module
    strangers = renderable_classes.reject { |klass| renders_by_the_rule?(klass) }

    assert_empty strangers.map { |klass| "#{klass}: #{foreign_doors(klass)}" },
                 "every renderable class in this SDK must include " \
                 "BaseCradle::RendersNamesOnly, which supplies #{RENDER_METHODS.join(', ')}. " \
                 "A class that does not inherits someone else's render — Hash's prints " \
                 "every pair, Object's dumps every ivar — and that is how a credential " \
                 "reaches a log with this suite green (0.10.2). If a class genuinely needs " \
                 "a different render, decide that in the PR that adds it and teach this " \
                 "test which class and why; do not hand-roll a fourth copy."
  end

  # The guard's own deliberate break, run in-process: the exact shape of the 0.10.2 bug — a
  # Hash descendant added to the SDK with no render of its own — must fail the test above.
  # Without this, a guard that silently matched nothing would look identical to a guard that
  # passed.
  def test_the_guard_fails_on_a_hash_descendant_that_brings_no_render
    with_probe_class(Class.new(Hash)) do |probe|
      assert_includes renderable_classes, probe,
                      "a Hash descendant defined in BaseCradle must be in scope for the " \
                      "render rule — that is the class the rule exists for"
      refute renders_by_the_rule?(probe),
             "a Hash descendant with no render of its own must fail the guard; it inherits " \
             "Hash#inspect, which prints every value"
    end
  end

  # The other half of the break: a class that includes the module passes. Proves the guard
  # is discriminating rather than simply always-red for a new class.
  def test_the_guard_passes_a_new_class_that_includes_the_module
    conforming = Class.new(Hash) do
      include BaseCradle::RendersNamesOnly
      private def render_body = keys.sort.join(", ")
    end

    with_probe_class(conforming) do |probe|
      assert renders_by_the_rule?(probe)
    end
  end

  # The lazy collections are out of scope, and deliberately so: they hold no wire data of
  # their own, and the credential they do hold is reached through Client#inspect, which
  # redacts it. Pinned so the exclusion stays a decision rather than an accident — if a
  # collection ever starts carrying record data, this is the test that has to change.
  def test_the_lazy_collections_are_the_documented_exclusion
    refute_empty collection_classes
    assert_empty collection_classes & renderable_classes

    rendered = @client.messages.inspect

    refute_includes rendered, FAKE_TOKEN,
                    "a collection's default render walks its ivars, and one of them is the " \
                    "client — so the rule still has to hold one hop down, through " \
                    "Client#inspect"
  end

  # --- the rule itself, through all three doors -------------------------------------------

  def test_a_client_renders_the_marker_and_never_the_token
    each_door(@client) do |door, rendered|
      refute_includes rendered, FAKE_TOKEN, "Client##{door} printed the raw token"
      assert_includes rendered, "token=[REDACTED]", "Client##{door} must carry the marker"
      assert_includes rendered, BASE_URL, "Client##{door} keeps the base URL, which is no secret"
    end
  end

  # The exact string, because it is documented in the README and was pinned before the
  # module existed: extracting the rule must not have reworded anyone's output.
  def test_extracting_the_module_did_not_change_what_a_client_prints
    assert_equal "#<BaseCradle::Client base_url=\"#{BASE_URL}\" token=[REDACTED]>", @client.inspect
  end

  def test_a_record_renders_its_field_names_and_never_its_values
    message = BaseCradle::Message.new(
      { "uuid" => "0199a1f2-4c7e-7c3a-9f11-2b6d5e8a9c04", "body" => "the-body-text" },
      client: @client
    )

    each_door(message) do |door, rendered|
      assert_equal "#<BaseCradle::Message body, uuid>", rendered,
                   "Message##{door} must print the field names, sorted, and nothing else"
    end
  end

  # `to_s` is the door interpolation and `puts` take, and before #212 a record had none of
  # its own — `"#{message}"` gave a heap address. That leaked nothing, but it meant two of
  # the three doors on the SDK's most common object were somebody else's.
  def test_a_record_interpolates_as_its_names_rather_than_a_heap_address
    message = BaseCradle::Message.new({ "uuid" => "u", "body" => "b" }, client: @client)

    assert_equal "#<BaseCradle::Message body, uuid>", "#{message}"
    refute_match(/0x[0-9a-f]+/, "#{message}")
  end

  def test_headers_render_their_names_and_never_a_senders_credential
    headers = BaseCradle::WebhookEventHeaders.new(
      { "Content-Type" => "application/json", "Authorization" => "Bearer sender-secret-value" }
    )

    each_door(headers) do |door, rendered|
      refute_includes rendered, "sender-secret-value", "WebhookEventHeaders##{door} leaked a value"
      assert_includes rendered, "Authorization"
      assert_includes rendered, "Content-Type"
    end
  end

  # --- the module's contract ---------------------------------------------------------------

  # nil means "nothing to show" and renders the bare class; the empty string is a body and
  # renders after a space. Folding the two would report a delivery carrying one header named
  # "" as a delivery carrying none.
  def test_a_nil_body_renders_the_bare_class_and_an_empty_body_does_not
    assert_equal "#<BaseCradle::WebhookEventHeaders>",
                 BaseCradle::WebhookEventHeaders.new({}).inspect
    refute_equal "#<BaseCradle::WebhookEventHeaders>",
                 BaseCradle::WebhookEventHeaders.new({ "" => "x" }).inspect
  end

  # `to_s` is late-bound rather than `alias to_s inspect`: an alias copies the method body,
  # so a subclass that redacts more in `inspect` would still be bypassed by interpolation.
  def test_to_s_follows_a_subclass_that_redacts_further
    stricter = Class.new(BaseCradle::Message) do
      def inspect = "#<redacted-entirely>"
    end.new({ "uuid" => "u" }, client: @client)

    assert_equal "#<redacted-entirely>", "#{stricter}"
  end

  # An includer that supplies no body fails loudly at the render rather than printing a
  # bare class name that would read as deliberate.
  def test_an_includer_with_no_body_says_so
    incomplete = Class.new { include BaseCradle::RendersNamesOnly }.new

    error = assert_raises(NotImplementedError) { incomplete.inspect }
    assert_includes error.message, "render_body"
  end

  private
    # Every class the SDK defines whose instances render as themselves: not an exception
    # (those render as their message, which this SDK authors) and not a lazy collection.
    def renderable_classes
      sdk_classes.reject { |klass| klass <= Exception }
                 .reject { |klass| klass.include?(BaseCradle::NotSerializableCollection) }
    end

    def collection_classes
      sdk_classes.select { |klass| klass.include?(BaseCradle::NotSerializableCollection) }
    end

    def sdk_classes
      BaseCradle.constants.map { |name| BaseCradle.const_get(name) }.grep(Class)
    end

    def renders_by_the_rule?(klass)
      foreign_doors(klass).empty?
    end

    # The doors this class does not get from the module, named — so the failure says which
    # of the three is missing and whose it is instead.
    def foreign_doors(klass)
      RENDER_METHODS.reject { |name| klass.instance_method(name).owner == BaseCradle::RendersNamesOnly }
                    .map { |name| "#{name} from #{klass.instance_method(name).owner}" }
    end

    # `pp` writes a trailing newline of its own; the render is the line, not the newline.
    def each_door(subject)
      yield :inspect, subject.inspect
      yield :to_s, "#{subject}"
      yield :pretty_print, PP.pp(subject, +"").chomp
    end

    # A class defined under BaseCradle for the length of the block and removed after, so the
    # reflective guard sees it exactly as it would see a real one — and so no other test in
    # this randomly-ordered suite ever meets it.
    def with_probe_class(klass)
      BaseCradle.const_set(:RenderGuardProbe, klass)
      yield BaseCradle::RenderGuardProbe
    ensure
      BaseCradle.send(:remove_const, :RenderGuardProbe)
    end
end
