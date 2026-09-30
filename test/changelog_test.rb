# frozen_string_literal: true

require "test_helper"

# A release edits the version in three coupled places — lib/basecradle/version.rb, the
# changelog's newest heading, and that heading's link definition. The release pipeline's
# guards compare the tag to the built gem and to main's tip; none of them can see the
# changelog. So a heading typed one version off merges green, and RubyGems publishes the
# version the *tree* names while the notes announce one that was never built.
#
# This is the check that reads the changelog (#196). It is a test rather than a workflow
# step so it fails on the PR that introduces the mismatch, not on a tag nobody can
# un-push. Sits at test/ rather than test/basecradle/ for the same reason readme_test.rb
# does: it tests a repo-root document, not a file under lib/basecradle/.
class ChangelogTest < Minitest::Test
  CHANGELOG = File.expand_path("../CHANGELOG.md", __dir__)
  GEMSPEC = File.expand_path("../basecradle.gemspec", __dir__)

  # "## [0.10.0] - 2026-09-30" — a released-version heading. This changelog keeps **no
  # `Unreleased` placeholder** (a deliberate departure from Keep a Changelog, recorded in
  # CHANGELOG.md's own header): every heading is a shipped version, so the newest one is
  # always the version the tree builds.
  HEADING = /^## \[([^\]]+)\]/

  # Bare X.Y.Z. Not Gem::Version.correct?, which accepts "0.10", "1", "0.1.0.pre.rc1" and
  # even " " — the same regex lib/basecradle/version.rb is held to, and the same shape
  # release.yml refuses to publish anything but.
  SEMVER = /\A\d+\.\d+\.\d+\z/

  def changelog
    @changelog ||= File.read(CHANGELOG)
  end

  def headings
    @headings ||= changelog.scan(HEADING).flatten
  end

  # The repo URL lives in the gemspec already; reading it keeps a rename from needing an
  # edit here too.
  def repo_url
    @repo_url ||= Gem::Specification.load(GEMSPEC).metadata.fetch("source_code_uri")
  end

  def test_the_newest_heading_names_the_version_this_tree_builds
    newest = headings.first

    refute_nil newest, "CHANGELOG.md has no '## [version]' heading at all"
    assert_equal BaseCradle::VERSION, newest,
                 "CHANGELOG.md's newest entry is [#{newest}] but lib/basecradle/version.rb " \
                 "says #{BaseCradle::VERSION}. A release edits both and nothing downstream " \
                 "can catch the disagreement — the tag guards compare the tag to the built " \
                 "gem, never to the notes. (If [#{newest}] is not a version at all, that is " \
                 "the fault: this changelog keeps no Unreleased placeholder.)"
  end

  # Headings are reference links, so one without its definition renders as literal
  # "[0.10.0]" on GitHub and RubyGems — which package the changelog. Every entry is
  # checked, not just the newest: the rendering breaks the same way for all of them.
  def test_every_heading_has_a_link_definition_pointing_at_its_own_tag
    headings.each do |version|
      expected = "[#{version}]: #{repo_url}/releases/tag/v#{version}"

      # Anchored: an indented line is a code block to Markdown, not a link definition,
      # so a substring match would pass while the reference still renders broken.
      assert_match(/^#{Regexp.escape(expected)}$/, changelog,
                   "CHANGELOG.md is missing the link definition for [#{version}]. Expected " \
                   "a line reading exactly, with no indentation:\n  #{expected}")
    end
  end

  # Ordering is what makes "the newest heading" meaningful — first in the file must be
  # the highest version, or every check above reads the wrong entry.
  #
  # Malformed headings are skipped rather than parsed: Gem::Version.new raises on one,
  # and an error here would mask the well-formedness test below, which reports it
  # properly. Minitest randomizes order, so neither test may depend on the other running.
  def test_entries_are_listed_newest_first
    versions = headings.grep(SEMVER).map { |v| Gem::Version.new(v) }

    assert_equal versions.sort.reverse, versions,
                 "CHANGELOG.md entries are out of order. Newest first, so the top entry " \
                 "is the release being cut."
  end

  # Cutting a release by copying the previous section and editing only the top heading
  # leaves the old one duplicated — which every other check here tolerates, because
  # duplicates are adjacent and compare equal.
  def test_no_version_is_listed_twice
    duplicated = headings.tally.select { |_, count| count > 1 }.keys

    assert_empty duplicated,
                 "CHANGELOG.md lists #{duplicated.join(', ')} more than once — usually a " \
                 "release section copied as a template with only the heading edited."
  end

  # A typo like "## [0.10]" or "## [v0.10.0]" would otherwise sail past the checks above:
  # Gem::Version pads "0.10" to 0.10.0, so it sorts correctly and reads as valid.
  def test_every_heading_is_a_well_formed_version
    headings.each do |version|
      assert_match SEMVER, version,
                   "CHANGELOG.md heading [#{version}] is not a bare X.Y.Z version. No " \
                   "leading 'v' — that belongs to the tag, not the entry — and all three " \
                   "segments, since that is the only shape release.yml will publish."
    end
  end
end
