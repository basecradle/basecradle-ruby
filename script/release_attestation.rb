# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"

# Whether a published gem version carries its sigstore attestation, read from RubyGems.org's
# public attestations endpoint. Run by `script/check-release-attestation`: last in
# release.yml's publish job (#297), and by hand in the rubygems-release skill's live verify.
#
# rubygems/release-gem signs the gem before it pushes it. When signing fails, for any reason,
# it logs `Failed to push with attestation, retrying without attestation.` and pushes the gem
# unsigned, and the job stays green. 0.14.2 went out that way (#286). A RubyGems version is
# immutable, so nothing here can repair such a release. This only turns it into a red job at
# the moment of the release, instead of a finding at verify time.
#
# Standard library only, and outside lib/ on purpose: lib/ is what the gem ships, and this is
# repository tooling, never part of the SDK.
class ReleaseAttestation
  ENDPOINT = "https://rubygems.org/api/v1/attestations/%s-%s.json"

  # How many times to ask while the registry has no answer yet, and how long to wait between
  # asks: five minutes of waiting, the window release-gem's own wait gives a release to
  # propagate. Each ask also gives up on a connection or a response after TIMEOUT seconds,
  # so a registry that hangs rather than answering stretches the whole to about fifteen.
  ATTEMPTS = 30
  INTERVAL = 10
  TIMEOUT = 10

  # The media type every sigstore bundle carries, whatever its version (0.14.1's is
  # `application/vnd.dev.sigstore.bundle.v0.3+json`).
  BUNDLE_MEDIA_TYPE = %r{\Aapplication/vnd\.dev\.sigstore\.bundle\b}

  # What a slow or unreachable registry raises. Only these mean "no answer yet": anything
  # else is a defect in this script, and must say so rather than wait out the window looking
  # like a slow registry.
  NETWORK_ERRORS = [ IOError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError,
                     Net::HTTPBadResponse, Net::ProtocolError ].freeze

  # A gem name as RubyGems allows it. Checked so that nothing but a name and a version can
  # reach the URL.
  NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  # One answer from the registry. :attested and :unattested are verdicts; :pending is not
  # one yet.
  Reading = Data.define(:state, :detail)

  # The command line: `script/check-release-attestation NAME VERSION`. Returns the exit
  # status: 0 when the version is attested, 1 when it is not or no verdict was reached, 2 on
  # bad arguments. Every failure is one `::error::` line, which GitHub Actions shows as an
  # annotation on the run.
  def self.run(argv, out: $stdout, attempts: ATTEMPTS, interval: INTERVAL)
    name, version = argv
    unless argv.size == 2 && valid?(name, version)
      out.puts "usage: script/check-release-attestation NAME VERSION (got #{argv.inspect})"
      return 2
    end

    full_name = "#{name}-#{Gem::Version.new(version)}"
    begin
      reading = check(name, version, out:, attempts:, interval:)
    rescue StandardError => e
      out.puts "::error::The attestation check for #{full_name} failed on its own: #{e.class}: " \
               "#{e.message}. This is a defect in script/release_attestation.rb, not a verdict on " \
               "the release. The gem is already published. Do not re-run this job; check the " \
               "attestation by hand (.claude/skills/rubygems-release, 'Verifying live')."
      return 1
    end

    case reading.state
    when :attested
      out.puts "#{full_name} carries its sigstore attestation (#{reading.detail})."
      0
    when :unattested
      out.puts "::error::#{full_name} was published with NO sigstore attestation. Signing failed " \
               "and release-gem pushed the gem unsigned (look for `Failed to push with attestation` " \
               "in the release step's log). The version is on RubyGems and cannot be replaced or " \
               "re-signed, so do not re-run this job: report it on the release issue, and the " \
               "fix ships with the next release."
      1
    else
      out.puts "::error::Could not confirm that #{full_name} carries its sigstore attestation: " \
               "RubyGems gave no verdict in #{attempts} attempts (last: #{reading.detail}). The " \
               "gem is already published. Do not re-run this job; check the attestation by hand " \
               "(.claude/skills/rubygems-release, 'Verifying live')."
      1
    end
  end

  # Asks the registry until it gives a verdict or the attempts run out, and returns the last
  # reading. Each attempt is logged to +out+. It always asks at least once.
  def self.check(name, version, out: $stdout, attempts: ATTEMPTS, interval: INTERVAL)
    uri = url(name, version)
    reading = nil
    [ attempts, 1 ].max.times do |attempt|
      sleep interval if attempt.positive?
      reading = fetch(uri)
      out.puts "#{uri}: #{reading.detail}"
      break unless reading.state == :pending
    end
    reading
  end

  def self.url(name, version)
    raise ArgumentError, "not a gem name and version: #{name.inspect}, #{version.inspect}" unless valid?(name, version)

    URI(format(ENDPOINT, name, Gem::Version.new(version)))
  end

  # What one response from the attestations endpoint says. Only a 200 carrying a JSON list is
  # an answer: the list is empty when the version was pushed unsigned, and holds the sigstore
  # bundles when it was signed. A version the registry does not know yet is a 404, and
  # anything else (an outage page, a redirect, JSON of another shape, a list holding anything
  # but sigstore bundles) is no answer yet. Counting a list of something else as attested
  # would be the silent green this check exists to end.
  #
  # An empty list is final, not a reason to ask again: release-gem sends the attestation in
  # the same request as the gem, so it is stored with the version or not at all.
  def self.read(status, body)
    return Reading.new(:pending, "HTTP #{status}") unless status == 200

    list = JSON.parse(body.to_s)
    return Reading.new(:pending, "HTTP 200, but the JSON is not a list") unless list.is_a?(Array)
    return Reading.new(:unattested, "no attestation") if list.empty?
    unless list.all? { |entry| entry.is_a?(Hash) && entry["mediaType"].to_s.match?(BUNDLE_MEDIA_TYPE) }
      return Reading.new(:pending, "HTTP 200, but the list holds something other than sigstore bundles")
    end

    Reading.new(:attested, "#{list.size} attestation#{"s" unless list.size == 1}")
  rescue JSON::ParserError
    Reading.new(:pending, "HTTP 200, but not JSON")
  end

  # One GET. A network error is no answer yet, never a verdict.
  def self.fetch(uri)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.get(uri.request_uri)
    end
    read(response.code.to_i, response.body)
  rescue *NETWORK_ERRORS => e
    Reading.new(:pending, "#{e.class}: #{e.message}")
  end

  def self.valid?(name, version)
    name.is_a?(String) && name.match?(NAME) &&
      version.is_a?(String) && !version.strip.empty? && Gem::Version.correct?(version)
  end
  private_class_method :valid?
end
