# frozen_string_literal: true

require "test_helper"
require "bundler"
require "yaml"

# .github/dependabot.yml carries this repository's half of the fleet's Dependabot policy
# (#327, basecradle/basecradle#874): a seven-day cooldown on every entry, a week's action
# bumps grouped into one pull request, and a `publish-path` group that the shared auto-merge
# sends to the capital instead of merging. Each of these fails silently when it is wrong. A
# missing cooldown proposes a release on its first day; a gem the group misses merges
# unread, on green CI that never ran the publish job it installs into. So the group is held
# equal to what the Gemfile and the gemspec declare, which is all Dependabot can move here:
# no Gemfile.lock is committed, so it never proposes a transitive gem.
#
# Sits at test/ beside ci_workflow_test.rb, for the same reason: it tests a repo-level file.
class DependabotConfigTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  GROUP = "publish-path"
  # A pattern Dependabot reads as one exact gem name: no wildcard, no glob.
  EXACT_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  def test_every_entry_waits_seven_days
    assert_equal %w[bundler github-actions], updates.map { |entry| entry["package-ecosystem"] }
    updates.each do |entry|
      assert_equal({ "default-days" => 7 }, entry["cooldown"], entry["package-ecosystem"])
    end
  end

  def test_a_weeks_action_bumps_arrive_as_one_pull_request
    assert_equal({ "github-actions" => { "patterns" => [ "*" ] } }, entry("github-actions")["groups"])
  end

  def test_the_publish_path_group_names_exactly_what_the_gemfile_and_gemspec_declare
    patterns = publish_path_patterns(config)

    assert_equal declared_gems, patterns.sort,
      "the `#{GROUP}` Dependabot group must name exactly the gems the Gemfile and the " \
      "gemspec declare (#327): release.yml's publish job installs the whole bundle while it " \
      "holds a credential, so a bump the group misses auto-merges unread"
  end

  # --- the reader itself, on fabricated configs ---------------------------------------------

  def test_the_reader_accepts_a_plain_group
    assert_equal %w[rake webmock], publish_path_patterns(fabricated)
  end

  def test_the_reader_refuses_a_group_ahead_of_it
    groups = { "everything" => { "patterns" => [ "*" ] }, GROUP => { "patterns" => %w[rake] } }

    assert_refused(/first group/, fabricated(groups: groups))
  end

  def test_the_reader_refuses_a_key_that_narrows_the_group
    [ { "exclude-patterns" => %w[rake] }, { "dependency-type" => "production" },
      { "update-types" => %w[minor] } ].each do |narrowing|
      groups = { GROUP => { "patterns" => %w[rake] }.merge(narrowing) }

      assert_refused(/only `patterns`/, fabricated(groups: groups))
    end
  end

  def test_the_reader_refuses_an_entry_that_drops_updates_before_they_reach_the_group
    %w[allow ignore].each do |key|
      assert_refused(/drop gems/, fabricated(key => [ { "dependency-name" => "rake" } ]))
    end
  end

  def test_the_reader_refuses_a_pattern_that_is_not_one_exact_name
    [ %w[rake*], %w[*], [ "rake", "rake" ], [ "" ] ].each do |patterns|
      assert_refused(/exact gem name|twice/, fabricated(groups: { GROUP => { "patterns" => patterns } }))
    end
  end

  private

  def config
    @config ||= YAML.safe_load_file(File.join(ROOT, ".github/dependabot.yml"))
  end

  def updates
    config.fetch("updates")
  end

  def entry(ecosystem, from = config)
    found = from.fetch("updates").select { |each| each["package-ecosystem"] == ecosystem }
    assert_equal 1, found.size, "dependabot.yml must have exactly one #{ecosystem} entry"
    found.first
  end

  # The bundler entry's `publish-path` patterns, read narrowly and failing closed on whatever
  # would narrow it unseen: another group ahead of it (Dependabot puts a gem in the first
  # group it matches), any key in the group but `patterns`, and an `allow` or `ignore` on
  # the entry, which drops updates before any group sees them.
  def publish_path_patterns(from)
    bundler = entry("bundler", from)
    narrowing = bundler.keys & %w[allow ignore]
    assert_empty narrowing, "the bundler entry's #{narrowing} can drop gems from Dependabot's updates"

    groups = bundler.fetch("groups", {})
    assert_equal GROUP, groups.keys.first, "`#{GROUP}` must be the bundler entry's first group"
    assert_equal [ "patterns" ], groups[GROUP].keys, "the `#{GROUP}` group must hold only `patterns`"

    patterns = groups[GROUP]["patterns"]
    inexact = patterns.grep_v(EXACT_NAME)
    assert_empty inexact, "every `#{GROUP}` pattern must be one exact gem name"
    assert_equal patterns.uniq, patterns, "`#{GROUP}` names a gem twice"
    patterns
  end

  # Every gem the Gemfile declares (the gemspec's development dependencies come in through
  # its `gemspec` line), plus the gemspec's runtime dependencies, which reach the bundle
  # through the gem itself. Read by Bundler's own DSL, never by a regex over the Gemfile.
  # The gem's own name is left out: its source is this checkout, which Dependabot never moves.
  def declared_gems
    spec = Gem::Specification.load(File.join(ROOT, "basecradle.gemspec"))
    definition = Bundler::Dsl.evaluate(File.join(ROOT, "Gemfile"), nil, {})
    names = definition.dependencies.map(&:name) + spec.runtime_dependencies.map(&:name)
    (names.uniq - [ spec.name ]).sort
  end

  def fabricated(groups: { GROUP => { "patterns" => %w[rake webmock] } }, **entry_keys)
    bundler = { "package-ecosystem" => "bundler", "directory" => "/", "groups" => groups }.merge(entry_keys)
    { "version" => 2, "updates" => [ bundler ] }
  end

  def assert_refused(message, config)
    error = assert_raises(Minitest::Assertion) { publish_path_patterns(config) }
    assert_match message, error.message
  end
end
