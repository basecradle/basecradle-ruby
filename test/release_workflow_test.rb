# frozen_string_literal: true

require "test_helper"
require "yaml"

# release.yml carries facts that are *contractual*, not merely conventional: its own
# filename and the name of the environment its publish job runs in. Both are registered at
# rubygems.org as this gem's trusted publisher, and OIDC matches on them — so a rename that
# reads as tidying silently breaks the trust relationship and the publish 403s. It fails on
# a `v*` tag, after the rehearsal is green and the capital has actuated the gate, and a tag
# pushed to a public repo is not really un-pushable.
#
# The publish job's `permissions:` are pinned here too (#208) — not as a contract with
# RubyGems but because they fail the same way: `id-token: write` is the whole of this gem's
# authentication, and dropping it leaves a green tree, a green actionlint, and a run that
# dies on a tag which has already cleared the gate.
#
# ci.yml (#200), the README and the CHANGELOG (#196) each had a test holding them honest;
# the workflow that publishes the gem had none (#203). #202 is the reason that matters: it
# corrected a comment in this file that had been wrong since the file was written and
# survived only because nobody read it. A file nobody reads is a file a test has to hold.
#
# What this cannot cover: whether these values still match the registration on RubyGems'
# side. That lives in someone else's database, is invisible to any test in the tree, and
# changes only by a deliberate re-registration (the form is in
# .claude/skills/rubygems-release). This pins our half of the contract — the half that
# drifts by accident.
#
# Sits at test/ rather than test/basecradle/ for the same reason ci_workflow_test.rb,
# changelog_test.rb and readme_test.rb do: it tests a repo-level file, not one under
# lib/basecradle/.
class ReleaseWorkflowTest < Minitest::Test
  WORKFLOWS = File.expand_path("../.github/workflows", __dir__)

  # The two contractual names, verbatim as registered.
  FILENAME = "release.yml"
  ENVIRONMENT = "rubygems"

  # The action that does the publishing. The publish job is found by the step that pushes
  # the gem rather than by its job key, because the key is ours to rename and the
  # environment is not: a job rename must stay green, while dropping the environment — the
  # edit that actually 403s — must not.
  PUBLISH_ACTION = "rubygems/release-gem"

  # The publish job's permissions, exhaustively — what it grants today, not a floor.
  #
  # `id-token: write` is the whole of this gem's authentication: it is what
  # rubygems/release-gem mints the OIDC token with, and Trusted Publishing has no stored
  # credential to fall back on.
  #
  # `contents: write` is the grant release-gem documents for the git operation `rake
  # release` *can* perform — but this pipeline is tag-triggered only, and by the time the
  # task runs the tag exists (release-gem does `git fetch --tags --force` first), so
  # bundler's `already_tagged?` skips `release:source_control_push` and no push is made.
  # It is pinned as the widest grant in this workflow rather than as a necessity: narrowing
  # it is a change to release.yml, which is the capital's to decide, and this equality is
  # what makes that decision deliberate instead of a silent edit.
  PUBLISH_PERMISSIONS = { "contents" => "write", "id-token" => "write" }.freeze

  # The workflow-level grant, exhaustively: what every job that does not set its own
  # `permissions:` inherits — here the rehearsal, which only builds a gem and installs it.
  WORKFLOW_PERMISSIONS = { "contents" => "read" }.freeze

  # Exactly one workflow in this repo may publish on a release tag, and it must be the file
  # RubyGems trusts. Renaming it, or adding a second tag-triggered workflow beside it, both
  # show up here — the first because the trusted filename stops existing, the second because
  # a publish path RubyGems never authorised is a publish path that 403s.
  #
  # "Tag-triggered" is *any* non-empty `tags:` filter, not the literal `v*` this repo uses.
  # A second workflow registered under `v*.*.*` or `*` matches every tag we actually cut,
  # so pinning the exact pattern would have looked past the thing this test exists to see.
  def test_the_workflow_a_release_tag_triggers_is_the_one_rubygems_trusts
    assert_equal [ FILENAME ], tag_triggered_workflows,
                 "RubyGems trusts this gem's publisher by workflow filename, so exactly " \
                 "one workflow may run on a tag push and it must be #{FILENAME}. Found: " \
                 "#{tag_triggered_workflows.inspect}. A rename here does not fail until a " \
                 "tag is pushed, and then it fails with a 403 from RubyGems rather than " \
                 "anything naming the rename. Re-register the publisher first " \
                 "(.claude/skills/rubygems-release) if this is deliberate."
  end

  # The environment is the gate: it is what holds the run until the capital actuates it, and
  # it is the second half of what RubyGems matches on. Dropping it publishes with no gate at
  # all; renaming it 403s.
  def test_the_publish_job_runs_in_the_contractual_environment
    environment = jobs.fetch(publish_key)["environment"]
    name = environment.is_a?(Hash) ? environment["name"] : environment

    assert_equal ENVIRONMENT, name,
                 "the #{publish_key} job must run in the #{ENVIRONMENT.inspect} " \
                 "environment (found #{name.inspect}) — RubyGems matches the trusted " \
                 "publisher on the environment name as well as the filename, and the " \
                 "environment is also the one manual gate in this repo, the capital's to " \
                 "actuate. Renaming it 403s on a tag; removing it publishes ungated."
  end

  # Nothing may reach RubyGems that the rehearsal has not cleared first. The rehearsal is
  # where the tag is checked against main's tip and against the version this tree builds —
  # guards that only mean something if the publish waits for them. A published version can
  # never be replaced, so this is the one dependency in the repo that cannot be advisory,
  # and the next two tests are the reason this one is not enough on its own.
  def test_the_publish_job_waits_on_the_rehearsal
    needed = needs(jobs.fetch(publish_key))

    assert_includes needed, rehearsal_key,
                    "the #{publish_key} job must list #{rehearsal_key.inspect} in its " \
                    "`needs` (found #{needed.inspect}). The rehearsal holds the guards " \
                    "that reject a tag on a stale commit or naming a version this tree " \
                    "does not build; a publish that does not wait for them pushes an " \
                    "immutable version from the wrong tree."
  end

  # `needs` is only as strong as the result the job it names reports. Job-level
  # `continue-on-error: true` makes a job report `success` however its steps exited, so a
  # rehearsal carrying it hands a failed guard to the publish as a pass — the dependency
  # above intact and meaningless. Pinned for every job here, not just the rehearsal: this
  # workflow's only purpose is to publish, so it has no job that may legitimately fail.
  # (ci.yml's gate is held to the same rule, for the same reason.)
  def test_no_job_in_the_release_swallows_its_own_failure
    swallowing = jobs.select { |_, job| job["continue-on-error"] }.keys

    assert_empty swallowing,
                 "#{FILENAME} sets job-level `continue-on-error` on " \
                 "#{swallowing.join(', ')}. A job with it reports `success` to everything " \
                 "waiting on it however its steps exited — so a rehearsal whose tag guards " \
                 "*failed* still releases the publish, and an immutable version goes to " \
                 "RubyGems from a tree nobody cleared. There is no advisory work in a " \
                 "release."
  end

  # The other way past a green `needs`: a condition that runs the publish anyway. `if:
  # always()` on the publish job is the exact mirror of ci.yml's gate — there it is what
  # makes the gate honest, here it is what makes the rehearsal optional. No condition at all
  # is the only shape that cannot do that, so any `if:` fails and asks for a deliberate
  # decision rather than being read for intent.
  def test_the_publish_job_carries_no_condition_that_could_outrun_the_rehearsal
    condition = jobs.fetch(publish_key)["if"]

    assert_nil condition,
               "the #{publish_key} job carries `if: #{condition}`. A condition here is how " \
               "a publish runs past a rehearsal it was supposed to wait for — `always()` " \
               "most directly, since it detaches the job from every result in its `needs`. " \
               "If a condition is genuinely wanted, decide it in the PR that adds it and " \
               "teach this test which ones keep the rehearsal binding."
  end

  # The publish job's `permissions` have the same failure shape as the two contractual names
  # above, and sit four lines from them. Drop `id-token: write` and the tree stays green —
  # `bundle exec rake` passes, `actionlint` passes, a narrower block being valid YAML and a
  # valid workflow — and the run dies on a `v*` tag, after the rehearsal has gone green and
  # after the capital has actuated the gate, which is the failure this file exists to move
  # earlier.
  #
  # Equality rather than containment, and the reason is this job specifically: it is the one
  # job in the repo that holds a write token, so a permission added here is a permission a
  # compromised action gets. A key *added* therefore fails too — including via the
  # `permissions: write-all` shorthand, which is a String and cannot equal the Hash either
  # way. (ci_workflow_test.rb also compares by equality, but for its own, different reason:
  # a `needs` entry naming a job that no longer exists stops CI running at all.)
  def test_the_publish_job_holds_exactly_the_permissions_the_publish_grants_today
    permissions = jobs.fetch(publish_key)["permissions"]

    assert_equal PUBLISH_PERMISSIONS, permissions,
                 "the #{publish_key} job must grant exactly #{PUBLISH_PERMISSIONS.inspect} " \
                 "(found #{permissions.inspect}). `id-token: write` is what " \
                 "#{PUBLISH_ACTION} mints the OIDC token with — drop it and there is no " \
                 "Trusted Publishing at all, and no stored credential to fall back on. " \
                 "`contents: write` is the grant release-gem documents for the git push " \
                 "`rake release` can make, which a tag-triggered run never reaches " \
                 "(`already_tagged?`); it is pinned as the widest grant here, so removing " \
                 "it is a deliberate decision about release.yml rather than a silent edit. " \
                 "A missing key is green in this tree and fails on a tag, after the gate " \
                 "has been actuated — and a tag pushed to a public repo is not really " \
                 "un-pushable. An extra key fails too: this is the only job here holding a " \
                 "write token."
  end

  # The workflow-level block is what every *other* job runs with — today the rehearsal, and
  # any job added later that does not say otherwise. A hardening pin rather than a
  # correctness one: widening it breaks no release, which is precisely why nothing else in
  # the repo would ever notice. Removing it is the worse of the two edits, since the token
  # then falls back to the repository's default workflow permissions — a setting outside
  # this tree, which can be read *and* write.
  def test_the_workflow_grants_read_by_default_and_nothing_more
    permissions = workflow["permissions"]

    assert_equal WORKFLOW_PERMISSIONS, permissions,
                 "#{FILENAME} must grant #{WORKFLOW_PERMISSIONS.inspect} at the workflow " \
                 "level (found #{permissions.inspect}). That is what the rehearsal runs " \
                 "with, and what any job added later without its own `permissions:` block " \
                 "inherits. Removing it does not fall back to nothing — it falls back to " \
                 "the repository's default workflow permissions, a setting outside this " \
                 "tree that may be read-write. The one job that needs more says so itself."
  end

  # The one-line bypass of the pin above: a job-level `permissions:` overrides the
  # workflow-level block entirely, so `permissions: write-all` on the rehearsal hands a
  # full read-write token to the job that fetches and builds an attacker-suppliable tag,
  # while the two assertions above stay green. Pinned as "no other job may declare
  # permissions at all" rather than "no other job may exceed the default", for the reason
  # `rehearsal_key` is strict about a third job: a release job that needs its own scopes
  # changes the shape of the release, and that is a decision to take in the PR that adds it
  # — and to teach this test — not one to infer.
  def test_no_job_but_the_publish_grants_itself_anything
    overriding = jobs.except(publish_key).select { |_, job| job.key?("permissions") }.keys

    assert_empty overriding,
                 "#{overriding.join(', ')} declares its own `permissions:`. A job-level " \
                 "block replaces the workflow-level #{WORKFLOW_PERMISSIONS.inspect} " \
                 "outright, so this is how a job quietly gets more than the default " \
                 "without touching the default — `write-all` on the rehearsal hands a " \
                 "read-write token to the job that builds an attacker-supplied tag. Only " \
                 "#{publish_key} may grant itself anything, because only it publishes. If " \
                 "a job genuinely needs a scope, decide it in the PR that adds it and " \
                 "teach this test which scope and why."
  end

  private
    def workflow_path
      File.join(WORKFLOWS, FILENAME)
    end

    # The release workflow, read strictly: this repo owns the file, and anything that stops
    # it parsing must name itself here rather than surfacing as a NoMethodError on nil, or
    # quietly emptying the assertions above. The whole document, not just its jobs, because
    # the workflow-level `permissions:` is one of the things pinned.
    #
    # Strict is right here and soft is right in `triggers` below, for one reason: that
    # reader walks every file in the directory, two of which this repo may not fix, while
    # this one reads the single file this repo owns and publishes with.
    def workflow
      @workflow ||= begin
        unless File.exist?(workflow_path)
          flunk ".github/workflows/#{FILENAME} does not exist. That filename is " \
                "contractual — it is registered at rubygems.org as this gem's trusted " \
                "publisher — so whatever replaced it cannot publish."
        end

        document =
          begin
            YAML.safe_load(File.read(workflow_path))
          rescue Psych::Exception, SystemCallError => e
            flunk ".github/workflows/#{FILENAME} could not be read: #{e.class} — " \
                  "#{e.message}. Psych's safe mode refuses some YAML that is otherwise " \
                  "legal — an alias (`*ref`), an unquoted date — so this may be a workflow " \
                  "that publishes fine and that this reader cannot see into; either way " \
                  "nothing below is checking it."
          end

        unless document.is_a?(Hash)
          flunk ".github/workflows/#{FILENAME} does not read as a workflow (parsed as " \
                "#{document.class}). An empty file is the usual cause, and it cannot " \
                "publish anything."
        end
        document
      end
    end

    # Same strictness one level down: `jobs:` present but empty parses fine and then fails
    # as a NoMethodError inside whichever assertion happened to run first.
    def jobs
      @jobs ||= begin
        defined = workflow["jobs"]
        unless defined.is_a?(Hash)
          flunk ".github/workflows/#{FILENAME} defines no jobs (`jobs:` read as " \
                "#{defined.class}). Every assertion here reads a job, so the file has " \
                "stopped describing a release rather than failing one of these checks."
        end
        defined
      end
    end

    # Every workflow in the directory, by filename. Both extensions: GitHub honours `.yaml`
    # as well as `.yml`, so a second publish path added under the other one must not slip
    # past the filename pin.
    def tag_triggered_workflows
      @tag_triggered_workflows ||= Dir.glob("*.{yml,yaml}", base: WORKFLOWS).sort.select do |file|
        push = triggers(file)["push"]
        push.is_a?(Hash) && !Array(push["tags"]).empty?
      end
    end

    # A workflow's triggers, or `{}` when the file cannot be read as a workflow at all — an
    # empty file, or YAML that Psych's safe mode refuses: an **alias** (`*ref`) or an
    # unquoted date. Not an anchor — a bare `&anchor` parses fine; it is the reference to
    # one that raises `Psych::AliasesNotEnabled`, and naming the wrong half sends whoever
    # hits it grepping for a construct that was never the problem.
    # Deliberately soft, because this directory holds two files this repo may not fix: the
    # capital's verbatim shared stubs (CLAUDE.md → Repo sovereignty). ci.yml already takes
    # that stance explicitly, linting them `continue-on-error: true` so that a finding in a
    # file we are forbidden to edit cannot wedge every PR here. A workflow this repo *does*
    # own gains nothing by hiding behind it: actionlint parses all of them on the same PR
    # and is inside the CI gate, so unparseable YAML of ours goes red there instead.
    #
    # Psych reads YAML 1.1 booleans, so `on:` comes back as the key `true` rather than the
    # string "on"; both are read, so a quoted key and a future Psych that stops folding it
    # each keep working. The array form (`on: [push, schedule]`) carries no filters, so it
    # is not a tag trigger and `{}` is the right answer for it too.
    # The local is named `document`, not `workflow`: `workflow` is a method on this class
    # now, and Ruby resolves a bare name to a local only from its assignment onward — so a
    # later edit referring to it above this line would silently read release.yml instead of
    # the file being inspected, and invert the filename pin with no error anywhere.
    def triggers(file)
      document = YAML.safe_load(File.read(File.join(WORKFLOWS, file)))
      return {} unless document.is_a?(Hash)

      on = document.key?(true) ? document[true] : document["on"]
      on.is_a?(Hash) ? on : {}
    rescue Psych::Exception, SystemCallError
      {}
    end

    # `needs:` accepts a bare string as well as a list.
    def needs(job)
      Array(job["needs"])
    end

    # The job that actually pushes the gem. Flunks rather than returning nil, so a release
    # workflow that has stopped publishing — or grown a second publish path — says so.
    def publish_key
      @publish_key ||= begin
        keys = jobs.select { |_, job| publishes?(job) }.keys
        unless keys.size == 1
          flunk "#{FILENAME} defines #{keys.size} jobs that run #{PUBLISH_ACTION}" \
                "#{" (#{keys.join(', ')})" unless keys.empty?}. Exactly one job publishes " \
                "this gem; with none, this file no longer describes a release at all."
        end
        keys.first
      end
    end

    # The rehearsal: the job that is not the publish. Deliberately derived rather than
    # matched by key, and deliberately strict — a third job in this workflow changes the
    # release's shape, and whether the publish must wait for it is a decision to take in the
    # PR that adds it, not one to infer from a name.
    def rehearsal_key
      @rehearsal_key ||= begin
        keys = jobs.keys - [ publish_key ]
        unless keys.size == 1
          flunk "#{FILENAME} defines #{keys.size} jobs besides the publish" \
                "#{" (#{keys.join(', ')})" unless keys.empty?}, so this test cannot tell " \
                "which one is the rehearsal the publish must wait for. Decide explicitly " \
                "whether the publish gates on the new job, and teach this test the answer."
        end
        keys.first
      end
    end

    # `uses:` carries a ref (`rubygems/release-gem@v1`); the action is the part before it.
    def publishes?(job)
      Array(job["steps"]).any? { |step| step["uses"].to_s.split("@").first == PUBLISH_ACTION }
    end
end
