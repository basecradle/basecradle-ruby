# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# The leak this fix closes only has teeth when ActiveSupport is loaded: its
# +Object#as_json+ is +instance_values+, walked recursively, so serializing anything that
# held a Client walked to the raw bc_uat_ token. Its +Enumerable#as_json+ calls +to_a+,
# which is the *other* half: a collection serialized as its fetched records (never as the
# client it holds — Enumerable#as_json shadows the ivar walk), after paging the whole
# resource from inside the render. A Client's ivars are eight collections, so serializing
# one did both.
#
# ActiveSupport's core_ext cannot be unloaded, so requiring it here would change the
# environment every other test runs under. It is loaded in a child process instead
# (test/support/active_support_probe.rb), which reports what it saw as JSON; this file
# judges the report. The probe runs once for the whole class.
class ActiveSupportTest < Minitest::Test
  include TestSupport

  PROBE = File.expand_path("../support/active_support_probe.rb", __dir__)
  LIB = File.expand_path("../../lib", __dir__)
  REFUSAL = "BaseCradle::NotSerializableError"

  # Every way a caller reaches the object, as the probe labels them. The last three are
  # the Marshal and Psych doors (#205): they are pinned offline too, since neither needs
  # ActiveSupport — but Rails.cache.write is the scenario that made them urgent, and it
  # happens in an app with ActiveSupport loaded, so they are observed here as well.
  SERIALIZATIONS = %w[as_json to_json nested encode held marshal yaml marshal_held].freeze

  # The three doors a render arrives through (#212). `pretty_print` is the one `inspect`
  # does not cover for a Hash descendant, which is the shape that leaked.
  RENDER_DOORS = %w[inspect to_s pretty_print].freeze

  def self.report
    @report ||= begin
      out, err, status = Open3.capture3(RbConfig.ruby, "-I#{LIB}", PROBE, TestSupport::FAKE_TOKEN)
      raise "ActiveSupport probe exited #{status.exitstatus}: #{err}#{out}" unless status.success?

      # The report is the last line, so a deprecation notice or a stray puts from
      # anything the child loads does not turn this into an opaque parse error.
      line = out.lines.map(&:strip).reject(&:empty?).last
      raise "ActiveSupport probe printed no report. stdout:\n#{out}\nstderr:\n#{err}" if line.nil?

      JSON.parse(line)
    end
  end

  def subjects
    self.class.report.fetch("subjects")
  end

  # The records: objects that render by the names-only rule and legitimately serialize.
  def records
    self.class.report.fetch("records")
  end

  # Without this the whole file could pass vacuously: if ActiveSupport were not really
  # loaded in the child, nothing would be walking ivars and the refusals below would be
  # proving nothing. The control is an ordinary object holding a harmless string, and it
  # must come out with its ivar serialized — the exact behaviour that made a Client
  # dangerous.
  def test_the_probe_really_runs_with_activesupports_ivar_walk_live
    control = self.class.report.fetch("control")

    assert_equal "returned", control["outcome"], control["message"]
    assert_equal({ "holder" => { "held" => "held-in-the-clear" } },
                 JSON.parse(JSON.parse(control.fetch("value"))))
  end

  # The probe's subject list is hand-written (the constructors differ), so completeness
  # is checked against the class list the probe finds reflectively. Add a collection and
  # forget the probe, and this fails — otherwise the new class would never be exercised
  # against real ActiveSupport, which is the only place the ordering trap below bites.
  def test_the_probe_covers_the_client_and_every_collection
    assert_includes subjects.keys, "Client"

    missing = self.class.report.fetch("enumerable_classes") - subjects.keys

    assert_empty missing, "test/support/active_support_probe.rb does not exercise #{missing.join(', ')}"
  end

  # The fix, under the conditions that made it necessary. Every route — the ActiveSupport
  # hook, to_json, nesting, Rails' own encoder, and one hop down inside a plain object —
  # refuses, for the client and for every lazy collection.
  def test_nothing_serializes_under_activesupport
    subjects.each do |name, observations|
      SERIALIZATIONS.each do |route|
        outcome = observations.fetch(route)

        assert_equal REFUSAL, outcome["outcome"],
                     "#{name}##{route} should refuse, got #{outcome.inspect}"
      end
    end
  end

  # ActiveSupport defines as_json/to_json on Enumerable itself. A collection includes
  # Enumerable too, so this passes only while the refusal sits ahead of it in the
  # ancestor chain — an include written in the wrong order would silently reopen the
  # hole, and nothing but this test would notice.
  def test_the_refusal_outranks_activesupports_enumerable_hook
    collections = subjects.reject { |name, _| name == "Client" }

    refute_empty collections
    collections.each do |name, observations|
      assert_equal REFUSAL, observations.dig("as_json", "outcome"), name
    end
  end

  # The second half of the DoD: refusing before any HTTP. The probe replaces the SDK's
  # one send path with a raise, so a collection that paged itself would report a
  # RuntimeError("HTTP issued") here instead of the refusal.
  def test_no_request_is_issued_while_serializing
    messages = subjects.values.flat_map { |obs| SERIALIZATIONS.map { |r| obs.dig(r, "message") } }

    refute_includes messages, "HTTP issued"
  end

  # The other door, checked in the same process: ActiveSupport does not touch inspect,
  # but a client rendered into an exception message or a log line must still be redacted,
  # and the resources hold the client so their default inspect renders it too.
  def test_inspect_and_to_s_never_carry_the_token
    subjects.each do |name, observations|
      refute_includes observations.fetch("inspect"), FAKE_TOKEN, name
      refute_includes observations.fetch("to_s"), FAKE_TOKEN, name
    end

    assert_includes subjects.dig("Client", "inspect"), "token=[REDACTED]"
    assert_includes subjects.dig("Client", "to_s"), "token=[REDACTED]"
  end

  # --- the records --------------------------------------------------------------------

  # The hole #212 closed. This harness excluded Hash descendants — reasonably, as a fact
  # about *serialization*, since a delivery's headers are a record and serialize — and
  # that exclusion silently answered a render question it had no bearing on. The result
  # was that the one class 0.10.2's security fix was written for was never rendered under
  # real ActiveSupport by the harness that exists for exactly that. Reflective, so a
  # second Hash descendant cannot repeat it.
  def test_the_probe_covers_every_hash_descendant_the_sdk_defines
    declared = self.class.report.fetch("hash_descendant_classes")

    refute_empty declared,
                 "the reflective sweep found no Hash descendant at all, so this " \
                 "assertion would pass without checking anything"

    missing = declared - records.keys

    assert_empty missing,
                 "test/support/active_support_probe.rb does not render " \
                 "#{missing.join(', ')}. A Hash descendant brings Hash's own render, " \
                 "which prints every value — that is how an inbound sender's credential " \
                 "reached a log in 0.10.2, and this environment is where a Rails app " \
                 "meets it."
  end

  # All three doors, under loaded ActiveSupport. `pretty_print` is here because `pp` is the
  # door `inspect` does not cover for a Hash descendant, and because #212 gave records
  # their to_s and pretty_print for the first time.
  def test_a_record_renders_its_names_and_never_its_values
    secrets = [ self.class.report.fetch("sender_secret"), self.class.report.fetch("record_secret") ]

    records.each do |name, observations|
      RENDER_DOORS.each do |door|
        rendered = observations.fetch(door)

        secrets.each { |secret| refute_includes rendered, secret, "#{name}##{door}" }
        refute_includes rendered, FAKE_TOKEN, "#{name}##{door}"
        assert_match(/\A#<BaseCradle::#{name} /, rendered,
                     "#{name}##{door} must name the class and its fields")
      end
    end

    assert_includes records.dig("WebhookEventHeaders", "inspect"), "Authorization"
    assert_includes records.dig("Message", "inspect"), "body"
  end

  # The other half, and the reason the records are their own bucket rather than added to
  # the list above: a record is *supposed* to serialize. The render rule must not have been
  # bought by breaking what these objects are for.
  def test_a_record_still_serializes_under_activesupport
    records.each do |name, observations|
      %w[as_json to_json].each do |route|
        observation = observations.fetch(route)

        assert_equal "returned", observation["outcome"],
                     "#{name}##{route} raised #{observation['outcome']}: " \
                     "#{observation['message']}. A record is not a connection — refusing " \
                     "here would break rendering a delivery in an app."
      end
    end

    assert_includes JSON.parse(records.dig("WebhookEventHeaders", "to_json", "value")),
                    "Authorization",
                    "the headers serialize as the delivery, verbatim — only the render is redacted"
  end
end
