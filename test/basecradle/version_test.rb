# frozen_string_literal: true

require "test_helper"

class VersionTest < Minitest::Test
  def test_version_is_a_semver_string
    assert_match(/\A\d+\.\d+\.\d+\z/, BaseCradle::VERSION)
  end

  # The gemspec reads the version from the constant — pin that wiring so a build can
  # never ship a version that disagrees with lib/basecradle/version.rb.
  def test_gemspec_version_matches_the_constant
    gemspec = Gem::Specification.load(File.expand_path("../../basecradle.gemspec", __dir__))

    assert_equal BaseCradle::VERSION, gemspec.version.to_s
  end
end
