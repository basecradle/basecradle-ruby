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

  # --- the Error Codes parser -------------------------------------------------------------

  def test_extracts_every_documented_code
    assert_equal codes, DriftGuard.documented_error_codes(error_codes_docs)
  end

  def test_reads_only_the_error_codes_section
    # Tables before the heading and after the section ends are not error codes.
    stray = "| Code | Status | When |\n|---|---|---|\n| `elsewhere` | 400 | Not ours. |\n"
    docs = error_codes_docs(before: stray, after: "## Rate Limiting\n#{stray}")

    refute_includes DriftGuard.documented_error_codes(docs), "elsewhere"
  end

  def test_a_row_without_an_anchor_still_counts
    docs = error_codes_docs.sub("| `not_a_viewer`{:#error-not_a_viewer} |", "| `not_a_viewer` |")
    assert_includes docs, "| `not_a_viewer` |" # the fixture really changed

    assert_includes DriftGuard.documented_error_codes(docs), "not_a_viewer"
  end

  def test_an_escaped_pipe_in_the_description_is_not_a_column
    docs = error_codes_docs.sub(
      "| `not_found`{:#error-not_found} | 400 | Something went wrong. |",
      "| `not_found`{:#error-not_found} | 404 | Missing \\| hidden. |"
    )
    assert_includes docs, "Missing \\| hidden." # the fixture really changed

    assert_includes DriftGuard.documented_error_codes(docs), "not_found"
  end

  def test_trailing_whitespace_and_crlf_are_tolerated
    docs = error_codes_docs.gsub("\n", "  \r\n")
    assert_includes docs, "|  \r\n" # the fixture really changed

    assert_equal codes, DriftGuard.documented_error_codes(docs)
  end

  def test_missing_heading_fails_loudly
    docs = error_codes_docs.sub("### Error Codes", "### Codes")
    assert_format_drift(docs, /format has likely changed/)
  end

  def test_duplicate_heading_fails_loudly
    # Two complete, valid sections: either alone would parse, so only the heading count can
    # refuse to pick one.
    assert_format_drift(error_codes_docs * 2, /Found 2 '### Error Codes' headings/)
  end

  def test_reshaped_header_row_fails_loudly
    docs = error_codes_docs.sub("| Code | Status | When |", "| Status | Code | When |")
    assert_format_drift(docs, /format has likely changed/)
  end

  def test_missing_separator_row_fails_loudly
    docs = error_codes_docs.sub("|---|---|---|\n", "")
    assert_format_drift(docs, /format has likely changed/)
  end

  def test_one_unparseable_row_fails_the_whole_read
    # The reason the guard is stricter than the spec's: a row must not drop silently.
    [
      "| not_found | 404 | No backticks. |",
      "| `not_found` | Not Found | A status that is not three digits. |",
      "| `not_found` | 404 |",
      "| `not_found` | 404 | An extra column. | x |",
      "| `Not-Found` | 404 | A code outside the snake_case alphabet. |",
      "| `not_found` | 404 |  |",
      "`not_found` | 404 | GFM's optional leading pipe, omitted. |",
      "  | `invalid_cursor`{:#error-invalid_cursor} | 400 | An indented row. |"
    ].each do |reshaped|
      docs = error_codes_docs.sub(
        "| `invalid_cursor`{:#error-invalid_cursor} | 400 | Something went wrong. |", reshaped
      )
      assert_includes docs, reshaped # the fixture really changed

      assert_format_drift(docs, /Unparseable Error Codes row/)
    end
  end

  def test_a_heading_inside_a_code_fence_does_not_end_the_section
    # A `# comment` in an example would otherwise stop the read before the rows below it.
    docs = error_codes_docs.sub(
      "The per-endpoint tables below.",
      "```sh\n# a shell comment\n```\n\n| `after_the_fence` | 400 | Still read. |"
    )

    assert_includes DriftGuard.documented_error_codes(docs), "after_the_fence"
  end

  def test_a_pipe_inside_a_code_fence_is_not_a_row
    docs = error_codes_docs.sub("The per-endpoint tables below.", "```\n| a | b |\n```")
    assert_includes docs, "| a | b |" # the fixture really changed

    assert_equal codes, DriftGuard.documented_error_codes(docs)
  end

  def test_too_few_codes_fails_loudly
    docs = error_codes_docs(codes: [ "not_found" ] + Array.new(13) { |i| "code_#{i}" })
    assert_format_drift(docs, /Parsed only \d+ error codes/)
  end

  # --- error-code comparison --------------------------------------------------------------

  def test_a_missing_registry_entry_is_reported
    BaseCradle::CODE_TO_ERROR.each_key do |code|
      broken = BaseCradle::CODE_TO_ERROR.except(code)
      assert_equal Set[code], DriftGuard.untyped(codes, broken)
    end
  end

  def test_a_fully_typed_catalog_reports_nothing
    assert_empty DriftGuard.untyped(codes, BaseCradle::CODE_TO_ERROR)
  end

  # --- coverage-map honesty (the map can't claim features that don't exist) ---------------

  def test_client_level_features_exist
    bc = BaseCradle::Client.new(FAKE_TOKEN)

    assert_respond_to BaseCradle::Client, :login
    assert_respond_to bc, :me
    assert_respond_to bc, :dashboard_md
    assert_respond_to bc, :sign_out
    assert_respond_to bc, :change_password
    %i[timelines messages assets tasks webhook_endpoints webhook_events sessions users].each do |r|
      assert_respond_to bc, r, "COVERAGE references bc.#{r}, which is gone"
    end
  end

  def test_model_verbs_exist
    {
      BaseCradle::Timeline => %i[lock add_participant remove_participant],
      BaseCradle::Task => %i[cancel],
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

  private

  def codes
    Set.new(BaseCradle::CODE_TO_ERROR.keys)
  end

  # A docs fixture shaped like the live Error Codes section, one row per code.
  def error_codes_docs(codes: self.codes, before: "", after: "## Rate Limiting\n")
    rows = codes.map { |code| "| `#{code}`{:#error-#{code}} | 400 | Something went wrong. |\n" }.join
    "#{before}## Errors\n\nThe envelope.\n\n### Error Codes\n\n" \
      "The `code` is the stable contract.\n\n" \
      "| Code | Status | When |\n|---|---|---|\n#{rows}\n" \
      "The per-endpoint tables below.\n\n#{after}"
  end

  def assert_format_drift(docs, pattern)
    error = assert_raises(RuntimeError) { DriftGuard.documented_error_codes(docs) }
    assert_match pattern, error.message
  end
end
