# frozen_string_literal: true

# The drift-guard's networked tests: one GET each of two public documents. The OpenAPI
# spec must have no endpoint the SDK doesn't cover, and the prose docs' Error Codes table
# no code without a typed exception. Run via `rake test:live` (its own CI job); excluded
# from the default offline `rake test`.
#
# Deliberately does NOT require test_helper — that disables all network access. This file
# is the one place the suite is allowed to reach the real API.
require "minitest/autorun"
require "net/http"
require "uri"

require "basecradle"
require "support/drift_guard"

class DriftGuardLiveTest < Minitest::Test
  def test_every_live_endpoint_is_covered
    spec = fetch(DriftGuard::LIVE_SPEC_URL)
    missing = DriftGuard.uncovered(DriftGuard.endpoint_pairs(spec), DriftGuard::COVERAGE)

    assert_empty missing.to_a.sort, <<~MSG
      The live API has #{missing.size} endpoint(s) the SDK does not cover: #{missing.to_a.sort.inspect}.
      This is the drift-guard working as intended — file an issue for each, add SDK coverage,
      and extend COVERAGE in test/support/drift_guard.rb.
    MSG
  end

  def test_every_documented_error_code_is_typed
    docs = fetch(DriftGuard::LIVE_DOCS_URL)
    missing = DriftGuard.untyped(DriftGuard.documented_error_codes(docs), BaseCradle::CODE_TO_ERROR)

    assert_empty missing.to_a.sort, <<~MSG
      The live docs list #{missing.size} error code(s) the SDK has no typed exception for:
      #{missing.to_a.sort.inspect}. Callers get a bare BaseCradle::Error for each. This is the
      drift-guard working as intended — file an issue for each, add the class, and map it in
      BaseCradle::CODE_TO_ERROR (lib/basecradle/errors.rb) and test/basecradle/errors_test.rb.
    MSG
  end

  private

  def fetch(url, redirects: 5)
    raise "too many redirects fetching #{url}" if redirects.negative?

    uri = URI.parse(url)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.get(uri.request_uri)
    end

    case response
    when Net::HTTPSuccess then response.body
    when Net::HTTPRedirection then fetch(URI.join(url, response["location"]).to_s, redirects: redirects - 1)
    else raise "fetching #{url} failed with HTTP #{response.code}"
    end
  end
end
