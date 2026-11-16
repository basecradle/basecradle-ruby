# frozen_string_literal: true

require "test_helper"
require "stringio"
require_relative "../script/release_attestation"

# The check that turns a release published without its sigstore attestation into a red job
# (#297). 0.14.2 went out unsigned while its publish job stayed green (#286): release-gem
# falls back to an unsigned push whenever signing fails. These tests pin what the check reads
# as a verdict, because each way it can be wrong is silent: a check that passes on an empty
# list is the green job all over again, and one that fails on a slow registry pages the
# capital over a release that went out fine.
#
# Sits at test/ rather than test/basecradle/ because it tests repository tooling under
# script/, not the SDK under lib/basecradle/.
class ReleaseAttestationTest < Minitest::Test
  URL = "https://rubygems.org/api/v1/attestations/basecradle-0.14.3.json"

  # The shape RubyGems serves for a signed version, trimmed: one sigstore bundle. The digest
  # and signature are fabricated.
  BUNDLE = {
    "mediaType" => "application/vnd.dev.sigstore.bundle.v0.3+json",
    "messageSignature" => {
      "messageDigest" => { "algorithm" => "SHA2_256", "digest" => "dGhpcyBpcyBub3QgYSByZWFsIGRpZ2VzdCEhISE=" },
      "signature" => "ZmFicmljYXRlZCBzaWduYXR1cmU="
    }
  }.freeze

  # --- reading one answer --------------------------------------------------------------

  def test_a_list_of_bundles_is_attested
    reading = ReleaseAttestation.read(200, JSON.generate([ BUNDLE ]))

    assert_equal :attested, reading.state
    assert_equal "1 attestation", reading.detail
    assert_equal "2 attestations", ReleaseAttestation.read(200, JSON.generate([ BUNDLE, BUNDLE ])).detail
  end

  # What RubyGems serves for 0.14.2 today, and the whole reason this check exists.
  def test_an_empty_list_is_unattested
    assert_equal :unattested, ReleaseAttestation.read(200, "[]").state
  end

  # A version the registry does not know yet is a 404 (measured: "This rubygem could not be
  # found."), and a server error is no answer. Neither is a verdict, either way.
  def test_anything_but_a_200_is_no_answer_yet
    [ 404, 429, 500, 502, 503, 301 ].each do |status|
      reading = ReleaseAttestation.read(status, "This rubygem could not be found.")

      assert_equal :pending, reading.state, "HTTP #{status}"
      assert_equal "HTTP #{status}", reading.detail
    end
  end

  # A 200 that is not a JSON list is a page from something in front of the registry, never
  # an empty list. Reading it as one would fail a signed release; reading it as attested
  # would pass an unsigned one.
  def test_a_200_that_is_not_a_json_list_is_no_answer_yet
    [ "<html>maintenance</html>", "", nil, "{}", "null", "\"[]\"" ].each do |body|
      assert_equal :pending, ReleaseAttestation.read(200, body).state, body.inspect
    end
  end

  # --- asking until there is a verdict -------------------------------------------------

  def test_a_signed_release_passes
    stub_request(:get, URL).to_return(status: 200, body: JSON.generate([ BUNDLE ]))

    status, out = run_check("basecradle", "0.14.3")

    assert_equal 0, status
    assert_match "basecradle-0.14.3 carries its sigstore attestation (1 attestation)", out
    refute_match "::error::", out
  end

  def test_an_unsigned_release_fails_loudly_at_the_first_answer
    stub_request(:get, URL).to_return(status: 200, body: "[]")

    status, out = run_check("basecradle", "0.14.3")

    assert_equal 1, status
    assert_requested :get, URL, times: 1
    error = sole_error(out)
    assert_match "basecradle-0.14.3 was published with NO sigstore attestation", error
    assert_match "do not re-run this job", error
  end

  # The registry may not serve the version for a moment after release-gem returns. The check
  # waits it out rather than failing a release that went out fine.
  def test_it_asks_again_until_the_registry_knows_the_version
    stub_request(:get, URL)
      .to_return(status: 404, body: "This rubygem could not be found.")
      .then.to_raise(Net::OpenTimeout)
      .then.to_return(status: 200, body: JSON.generate([ BUNDLE ]))

    status, out = run_check("basecradle", "0.14.3")

    assert_equal 0, status
    assert_requested :get, URL, times: 3
    assert_match "#{URL}: HTTP 404", out
    assert_match "#{URL}: Net::OpenTimeout", out
  end

  # It keeps asking only while there is no answer. An empty list after a 404 is still final.
  def test_an_empty_list_after_a_wait_still_fails
    stub_request(:get, URL)
      .to_return(status: 404, body: "This rubygem could not be found.")
      .then.to_return(status: 200, body: "[]")

    status, out = run_check("basecradle", "0.14.3")

    assert_equal 1, status
    assert_requested :get, URL, times: 2
    assert_match "was published with NO sigstore attestation", out
  end

  # No verdict is not a pass. It fails, and says the gem is already out, so nobody re-runs a
  # publish that cannot be repeated.
  def test_no_verdict_in_time_fails_and_says_the_gem_is_already_published
    stub_request(:get, URL).to_return(status: 503, body: "Service Unavailable")

    status, out = run_check("basecradle", "0.14.3", attempts: 4)

    assert_equal 1, status
    assert_requested :get, URL, times: 4
    error = sole_error(out)
    assert_match "Could not confirm that basecradle-0.14.3 carries its sigstore attestation", error
    assert_match "in 4 attempts (last: HTTP 503)", error
    assert_match "The gem is already published. Do not re-run this job", error
  end

  # Five minutes, like release-gem's own wait.
  def test_by_default_it_waits_five_minutes
    assert_equal 300, ReleaseAttestation::ATTEMPTS * ReleaseAttestation::INTERVAL
  end

  # --- what reaches the URL ------------------------------------------------------------

  # The version names the gem file the way RubyGems does, so a version written with a
  # hyphen asks for the file RubyGems actually holds.
  def test_the_url_names_the_gem_the_way_rubygems_does
    assert_equal URL, ReleaseAttestation.url("basecradle", "0.14.3").to_s
    assert_equal "https://rubygems.org/api/v1/attestations/basecradle-1.0.0.pre.rc1.json",
                 ReleaseAttestation.url("basecradle", "1.0.0-rc1").to_s
  end

  # The version comes from a tag, which anyone who can push one chooses. Nothing but a gem
  # name and a version reaches the URL, and bad arguments ask for nothing.
  def test_anything_but_a_name_and_a_version_is_refused_before_any_request
    [ [], [ "basecradle" ], [ "basecradle", "0.14.3", "extra" ], [ "basecradle", "" ], [ "basecradle", " " ],
      [ "basecradle", "../../gems/x" ], [ "../basecradle", "0.14.3" ], [ "basecradle?x=", "0.14.3" ],
      [ "", "0.14.3" ] ].each do |argv|
      status, out = run_check(*argv)

      assert_equal 2, status, argv.inspect
      assert_match "usage: script/check-release-attestation NAME VERSION", out
    end
    assert_not_requested :get, /rubygems\.org/
  end

  private
    # The run's one `::error::` line: GitHub shows each as its own annotation, so a failure
    # says what happened once.
    def sole_error(out)
      errors = out.lines.grep(/\A::error::/)
      assert_equal 1, errors.size, out
      errors.first
    end

    def run_check(*argv, attempts: ReleaseAttestation::ATTEMPTS)
      out = StringIO.new
      status = ReleaseAttestation.run(argv, out:, attempts:, interval: 0)
      [ status, out.string ]
    end
end
