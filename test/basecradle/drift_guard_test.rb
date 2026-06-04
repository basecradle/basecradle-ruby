# frozen_string_literal: true

require "test_helper"
require "support/drift_guard"

# Offline meta-tests: prove the drift-guard's mechanism works (no network). The one
# networked check lives in test/live/drift_guard_live_test.rb (run via `rake test:live`).
class DriftGuardTest < Minitest::Test
  include TestSupport

  # --- the parser -------------------------------------------------------------------------

  def test_extracts_every_method_path_pair
    spec = +"paths:\n"
    20.times { |i| spec << %(  "/r#{i}":\n    get:\n      summary: index\n    post:\n      summary: create\n) }
    spec << %(  "/session":\n    post:\n      summary: create\n)

    pairs = DriftGuard.endpoint_pairs(spec)

    assert_includes pairs, [ "GET", "/r0" ]
    assert_includes pairs, [ "POST", "/r19" ]
    assert_includes pairs, [ "POST", "/session" ]
    assert_equal 41, pairs.size
  end

  def test_too_few_pairs_fails_loudly
    fixture = %(paths:\n  "/things":\n    get:\n    post:\n)
    error = assert_raises(RuntimeError) { DriftGuard.endpoint_pairs(fixture) }
    assert_match(/format has likely changed/, error.message)
  end

  def test_unrecognizable_format_fails_loudly
    assert_raises(RuntimeError) { DriftGuard.endpoint_pairs("paths:\n  /unquoted:\n    get:\n") }
  end

  def test_nested_keys_are_not_mistaken_for_methods
    spec = +"paths:\n"
    30.times { |i| spec << %(  "/r#{i}":\n    get:\n      properties:\n        delete:\n) }
    spec << %(  "/session":\n    post:\n      summary: create\n)

    pairs = DriftGuard.endpoint_pairs(spec)

    # Only the 4-space-indented methods count: 30 GETs + 1 POST, zero DELETEs.
    assert_equal 31, pairs.size
    refute(pairs.any? { |method, _| method == "DELETE" })
  end

  # --- coverage comparison ----------------------------------------------------------------

  def test_a_missing_coverage_entry_is_reported
    DriftGuard::COVERAGE.each_key do |entry|
      broken = DriftGuard::COVERAGE.reject { |k, _| k == entry }
      assert_equal Set[entry], DriftGuard.uncovered(Set.new(DriftGuard::COVERAGE.keys), broken)
    end
  end

  def test_full_coverage_reports_nothing
    live = Set.new(DriftGuard::COVERAGE.keys)
    assert_empty DriftGuard.uncovered(live, DriftGuard::COVERAGE)
  end

  def test_coverage_can_be_a_superset_of_the_live_api
    live = Set.new(DriftGuard::COVERAGE.keys) - Set[[ "GET", "/users" ]]
    assert_empty DriftGuard.uncovered(live, DriftGuard::COVERAGE)
  end

  # --- coverage-map honesty (the map can't claim features that don't exist) ---------------

  def test_client_level_features_exist
    bc = BaseCradle::Client.new(FAKE_TOKEN)

    assert_respond_to BaseCradle::Client, :login
    assert_respond_to bc, :me
    %i[timelines messages assets tasks webhook_endpoints webhook_events sessions users].each do |r|
      assert_respond_to bc, r, "COVERAGE references bc.#{r}, which is gone"
    end
  end

  def test_model_verbs_exist
    {
      BaseCradle::Timeline => %i[lock add_participant remove_participant],
      BaseCradle::User => %i[grant_trust revoke_trust],
      BaseCradle::Session => %i[revoke],
      BaseCradle::WebhookEndpoint => %i[enable disable rotate]
    }.each do |model, verbs|
      verbs.each do |verb|
        assert model.method_defined?(verb), "COVERAGE references #{model}##{verb}, which is gone"
      end
    end
  end

  def test_every_covered_endpoint_names_a_real_feature
    DriftGuard::COVERAGE.each do |(method, path), feature|
      refute_empty feature.to_s, "(#{method}, #{path}) has an empty coverage description"
    end
  end
end
