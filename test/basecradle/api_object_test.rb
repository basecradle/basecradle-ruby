# frozen_string_literal: true

require "test_helper"

class ApiObjectTest < Minitest::Test
  include TestSupport

  # A couple of throwaway model classes exercising the DSL.
  class Inner < BaseCradle::ApiObject
    attribute :label
  end

  class Sample < BaseCradle::ApiObject
    attribute :name
    attribute :inner, wrap: Inner
    attribute :items, wrap: Inner
  end

  def test_attribute_returns_the_wire_value
    assert_equal "John Doe", Sample.new({ "name" => "John Doe" }).name
  end

  def test_missing_declared_field_raises_with_a_helpful_message
    error = assert_raises(BaseCradle::MissingFieldError) { Sample.new({}).name }

    assert_match(/did not return "name"/, error.message)
    assert_match(/Fields present: \[\]/, error.message)
    assert_kind_of BaseCradle::Error, error
  end

  def test_bracket_access_reads_raw_wire_including_undeclared_fields
    object = Sample.new({ "name" => "x", "added_later" => 42 })

    assert_equal 42, object["added_later"] # newer than the SDK, still readable
    assert_nil object["absent"]            # absent → nil, no raise (raw access)
  end

  def test_nested_hash_is_wrapped
    object = Sample.new({ "inner" => { "label" => "deep" } })

    assert_instance_of Inner, object.inner
    assert_equal "deep", object.inner.label
  end

  def test_nested_array_of_hashes_is_wrapped
    object = Sample.new({ "items" => [ { "label" => "a" }, { "label" => "b" } ] })

    assert_equal %w[a b], object.items.map(&:label)
    assert(object.items.all?(Inner))
  end

  def test_equality_and_hash_are_value_based
    a = Sample.new({ "name" => "x" })
    b = Sample.new({ "name" => "x" })
    c = Sample.new({ "name" => "y" })

    assert_equal a, b
    refute_equal a, c
    assert_equal a.hash, b.hash
    assert_equal 1, [ a, b ].uniq.size
  end

  def test_inspect_lists_fields_without_dumping_values
    assert_equal "#<#{Sample} inner, name>", Sample.new({ "name" => "x", "inner" => {} }).inspect
  end

  # --- serialization ----------------------------------------------------------------------

  # A model serializes as the record it stands for. Without to_json it fell through to
  # Ruby's default to_s and emitted a heap address — silently, and differently every run.
  def test_to_json_emits_the_wire_record
    object = Sample.new({ "name" => "x" })

    assert_equal({ "name" => "x" }, JSON.parse(object.to_json))
    assert_equal({ "name" => "x" }, JSON.parse(JSON.generate(object)))
  end

  # The shapes that matter in practice: a model rarely serializes alone, it serializes
  # inside the document a caller is building.
  def test_a_model_nested_in_an_array_or_a_hash_serializes_too
    a = Sample.new({ "name" => "a" })
    b = Sample.new({ "name" => "b" })

    assert_equal [ { "name" => "a" }, { "name" => "b" } ], JSON.parse([ a, b ].to_json)
    assert_equal({ "items" => [ { "name" => "a" } ], "one" => { "name" => "b" } },
                 JSON.parse({ "items" => [ a ], "one" => b }.to_json))
  end

  # Nested wire structure goes out whole — serializing reads the wire, exactly as the
  # field readers do, rather than stopping at the top level.
  def test_nested_content_serializes_whole
    object = Sample.new({ "name" => "x", "inner" => { "label" => "deep" },
                          "items" => [ { "label" => "a" }, { "label" => "b" } ] })

    assert_equal({ "name" => "x", "inner" => { "label" => "deep" },
                   "items" => [ { "label" => "a" }, { "label" => "b" } ] },
                 JSON.parse(object.to_json))
  end

  # as_json hands back the wire Hash unchanged — nothing renamed, nothing dropped.
  # Compared against a separately-built literal, not the constructor's own argument,
  # which would be comparing the object to itself.
  def test_as_json_is_the_wire_hash
    object = Sample.new({ "name" => "x", "inner" => { "label" => "deep" } })

    assert_equal({ "name" => "x", "inner" => { "label" => "deep" } }, object.as_json)
  end

  # The leak this fix closes, pinned. A model carries @client, and @client carries the
  # bearer token — before ApiObject had these methods, ActiveSupport's Object#as_json
  # fell back to instance_values and would serialize both. Serializing a model must
  # never reach anything but its wire record.
  def test_serializing_a_client_attached_model_never_reaches_the_client
    bc = BaseCradle::Client.new(FAKE_TOKEN)
    object = Sample.new({ "name" => "x" }, client: bc)

    assert_equal({ "name" => "x" }, JSON.parse(object.to_json))
    refute_includes object.to_json, FAKE_TOKEN
    refute_includes object.as_json.keys, "client"
  end

  # It is the *same* Hash to_h returns, not a copy, so it carries to_h's read-only
  # convention. Pinned with assert_same because a value test cannot tell the two apart,
  # and the difference is what decides whether a caller can mutate the result.
  def test_as_json_aliases_the_wire_hash_rather_than_copying_it
    object = Sample.new({ "name" => "x" })

    assert_same object.to_h, object.as_json
  end

  # Options are accepted and ignored — this is a read of one record, not a presenter.
  # The dangerous one is exercised on purpose: except: does NOT redact, and a caller
  # who assumes it does would ship the field they meant to drop.
  def test_as_json_ignores_options_including_the_redacting_ones
    object = Sample.new({ "name" => "x", "secret" => "s" })

    assert_equal({ "name" => "x", "secret" => "s" }, object.as_json(root: true))
    assert_equal({ "name" => "x", "secret" => "s" }, object.as_json(except: [ "secret" ]))
    assert_equal({ "name" => "x", "secret" => "s" }, object.as_json(only: [ "name" ]))
  end

  # to_json forwards its argument to Hash#to_json rather than swallowing it, so a
  # generator state reaches the wire Hash and pretty-printing works.
  def test_to_json_forwards_its_generator_state
    object = Sample.new({ "name" => "x" })

    assert_equal "{\n  \"name\": \"x\"\n}", JSON.pretty_generate(object)
  end

  # Serializing is a read: it must not rename a field or drop one the SDK never declared.
  def test_serializing_neither_renames_nor_drops_an_undeclared_field
    object = Sample.new({ "name" => "x", "field_from_a_later_release" => 7 })

    assert_equal({ "name" => "x", "field_from_a_later_release" => 7 },
                 JSON.parse(object.to_json))
  end
end
