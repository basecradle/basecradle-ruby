# frozen_string_literal: true

require "test_helper"

class ApiObjectTest < Minitest::Test
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
end
